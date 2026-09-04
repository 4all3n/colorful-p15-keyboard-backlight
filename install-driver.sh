#!/usr/bin/env bash
#
# install-driver.sh — build & install the patched tuxedo_keyboard driver that
# makes the keyboard backlight work on COLORFUL P15 23 and similar Tongfang/Clevo
# laptops whose firmware reports an *unrecognized* backlight type.
#
# Adapted for Arch Linux / CachyOS.
#
#   sudo ./install-driver.sh                 # auto: force 1-zone RGB only if needed
#   sudo FORCE_TYPE=2 ./install-driver.sh    # force a specific type (2=3-zone, 6=1-zone, 243=per-key)
#   sudo FORCE_TYPE=auto ./install-driver.sh # never force (rely on firmware detection)
#   sudo KVER=7.2.2-1-cachyos ./install-driver.sh  # build for a specific kernel
#
# Installs via DKMS, so it survives kernel updates automatically.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo ./install-driver.sh"; exit 1; }

REPO="https://gitlab.com/commown/tuxedo-drivers"
PIN="4e1fb3a8897708676ba76603f15e20ce7e9ad5fe"   # commit this patch + dkms layout match
PATCH="$HERE/driver/0001-colorful-p15-kbd-backlight.patch"
LED=/sys/class/leds/rgb:kbdlight

# ---- kernel version detection -----------------------------------------------
# Use KVER env-var if set; otherwise prefer the running kernel if its headers
# are present; as a last resort pick the newest installed kernel that has headers
# (handles the common case of "pacman updated the kernel but I haven't rebooted").
if [ -n "${KVER:-}" ]; then
    echo "==> using user-specified kernel: $KVER"
elif [ -d "/lib/modules/$(uname -r)/build" ]; then
    KVER="$(uname -r)"
else
    echo "NOTE: headers for running kernel $(uname -r) not found (kernel updated but not yet rebooted?)."
    KVER=""
    for d in /lib/modules/*/build; do
        [ -d "$d" ] || continue
        KVER="$(basename "$(dirname "$d")")"
    done
    if [ -n "$KVER" ]; then
        echo "    → found headers for $KVER — building for that kernel."
        echo "    → reboot into the new kernel after this finishes."
    else
        echo "ERROR: no kernel headers found under /lib/modules/*/build."
        echo "       Install the correct headers package for your kernel."
        exit 1
    fi
fi

# ---- Arch / CachyOS dependency installation ---------------------------------
echo "==> dependencies (Arch/CachyOS)"

# Detect which kernel headers package to install.
# CachyOS uses custom kernel packages like linux-cachyos, linux-cachyos-lts, etc.
# Their headers are named linux-cachyos-headers, linux-cachyos-lts-headers, etc.
# Standard Arch kernels: linux -> linux-headers, linux-lts -> linux-lts-headers, etc.
HEADERS_PKG=""
if pacman -Qi linux-cachyos &>/dev/null; then
    HEADERS_PKG="linux-cachyos-headers"
elif pacman -Qi linux-cachyos-lts &>/dev/null; then
    HEADERS_PKG="linux-cachyos-lts-headers"
elif pacman -Qi linux-cachyos-bore &>/dev/null; then
    HEADERS_PKG="linux-cachyos-bore-headers"
elif pacman -Qi linux-cachyos-rt &>/dev/null; then
    HEADERS_PKG="linux-cachyos-rt-headers"
elif pacman -Qi linux-cachyos-hardened &>/dev/null; then
    HEADERS_PKG="linux-cachyos-hardened-headers"
elif pacman -Qi linux-lts &>/dev/null && [[ "$KVER" == *lts* ]]; then
    HEADERS_PKG="linux-lts-headers"
elif pacman -Qi linux-zen &>/dev/null && [[ "$KVER" == *zen* ]]; then
    HEADERS_PKG="linux-zen-headers"
elif pacman -Qi linux-hardened &>/dev/null && [[ "$KVER" == *hardened* ]]; then
    HEADERS_PKG="linux-hardened-headers"
else
    HEADERS_PKG="linux-headers"
fi
echo "    detected kernel headers package: $HEADERS_PKG"

pacman -S --needed --noconfirm base-devel dkms git "$HEADERS_PKG"

# Verify kernel headers are actually present
if [ ! -d "/lib/modules/$KVER/build" ]; then
    echo "ERROR: kernel headers for $KVER not found at /lib/modules/$KVER/build"
    echo "       install the correct headers package for your running kernel."
    exit 1
fi

echo "==> fetch driver source (Commown fork @ ${PIN:0:7}) and apply patch"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
git clone -q "$REPO" "$WORK/src"
git -C "$WORK/src" checkout -q "$PIN"
git -C "$WORK/src" apply "$PATCH"
echo "    patch applied."

# Extract version: try debian/changelog first, fallback to Makefile or dkms.conf
VER=""
if [ -f "$WORK/src/debian/changelog" ]; then
    VER="$(grep -Pom1 '.* \(\K.*(?=\) .*; urgency=.*)' "$WORK/src/debian/changelog" 2>/dev/null || true)"
fi
if [ -z "$VER" ] && [ -f "$WORK/src/dkms.conf" ]; then
    VER="$(grep -Po 'PACKAGE_VERSION="\K[^"]+' "$WORK/src/dkms.conf" 2>/dev/null || true)"
fi
if [ -z "$VER" ]; then
    VER="0.0.1-custom"
    echo "    WARNING: could not detect version, using $VER"
fi
echo "    driver version: $VER"

# Detect if target kernel was built with LLVM/Clang (common in CachyOS)
MAKE_OPTS=""
if [ -f "/lib/modules/$KVER/build/.config" ] \
   && grep -q 'CONFIG_CC_IS_CLANG=y' "/lib/modules/$KVER/build/.config" 2>/dev/null; then
    echo "    target kernel ($KVER) built with clang — using LLVM=1"
    MAKE_OPTS="LLVM=1"
elif grep -qi "clang version" /proc/version 2>/dev/null; then
    echo "    running kernel built with clang — using LLVM=1"
    MAKE_OPTS="LLVM=1"
fi

echo "==> enumerate modules and generate dkms.conf"
# NB: this repo's Makefile uses M=$(PWD), so build from *inside* the dir
# (`make -C dir` would leave $(PWD) wrong and fail).
# Pass KDIR explicitly so the build works even when uname -r ≠ target kernel.
( cd "$WORK/src" && make $MAKE_OPTS KDIR="/lib/modules/$KVER/build" ) >/dev/null 2>&1
{
  echo 'PACKAGE_NAME="tuxedo-drivers"'
  echo "PACKAGE_VERSION=\"$VER\""
  echo 'AUTOINSTALL="yes"'
  # ${kernelver} is a DKMS magic variable: it always resolves to the kernel
  # being built for (not the currently running one).  This is what makes
  # auto-rebuild on kernel updates actually work.
  if [ -n "$MAKE_OPTS" ]; then
      echo "MAKE[0]=\"make KDIR=/lib/modules/\${kernelver}/build $MAKE_OPTS\""
  else
      echo 'MAKE[0]="make KDIR=/lib/modules/${kernelver}/build"'
  fi
  echo ''
  i=0
  for ko in $(cd "$WORK/src" && find src -name '*.ko' | sort); do
    echo "BUILT_MODULE_NAME[$i]=\"$(basename "$ko" .ko)\""
    echo "BUILT_MODULE_LOCATION[$i]=\"$(dirname "$ko")/\""
    echo "DEST_MODULE_LOCATION[$i]=\"/updates\""
    echo ''
    i=$((i+1))
  done
} > "$WORK/src/dkms.conf"
( cd "$WORK/src" && make $MAKE_OPTS KDIR="/lib/modules/$KVER/build" clean ) >/dev/null 2>&1

echo "==> install via DKMS"
DEST="/usr/src/tuxedo-drivers-$VER"
dkms remove -m tuxedo-drivers -v "$VER" --all >/dev/null 2>&1 || true
rm -rf "$DEST"; cp -r "$WORK/src" "$DEST"
dkms add    -m tuxedo-drivers -v "$VER" >/dev/null
dkms install -m tuxedo-drivers -v "$VER" -k "$KVER" --force >/dev/null
echo "    $(dkms status tuxedo-drivers | tail -1)"

# --- figure out the backlight type the firmware reports -----------------------
echo "==> probing keyboard backlight type"
modprobe -r tuxedo_io clevo_wmi clevo_acpi uniwill_wmi tuxedo_keyboard 2>/dev/null || true
MARK="kbdlight-probe-$$"                      # marker so we read only THIS probe's log
echo "$MARK" > /dev/kmsg 2>/dev/null || true
echo 'module tuxedo_keyboard +p' > /sys/kernel/debug/dynamic_debug/control 2>/dev/null || true
# force=-1 ensures we see the genuine firmware value, not any /etc/modprobe.d override
modprobe tuxedo_keyboard dyndbg=+p force_clevo_kb_backlight_type=-1 2>/dev/null || modprobe tuxedo_keyboard
modprobe clevo_acpi 2>/dev/null || true
modprobe clevo_wmi  2>/dev/null || true
sleep 1
PROBE="$(dmesg | sed -n "/$MARK/,\$p")"
# prefer the raw GET_SPECS type byte (authoritative); fall back to the parsed type line
DET_HEX="$(printf '%s\n' "$PROBE" | grep -oiE 'pointer\[0x0f\]: 0x[0-9a-f]+' | grep -oiE '0x[0-9a-f]+$' | tail -1 || true)"
[ -z "$DET_HEX" ] && DET_HEX="$(printf '%s\n' "$PROBE" | grep -oiE 'Keyboard backlight type: 0x[0-9a-f]+' | grep -oiE '0x[0-9a-f]+' | tail -1 || true)"
DET=$(( ${DET_HEX:-0} ))
echo "    firmware reports type: ${DET_HEX:-unknown}"

# known types: 0x01 fixed, 0x02 3-zone, 0x06 1-zone, 0xf3 per-key
FORCE="${FORCE_TYPE:-}"
if [ "$FORCE" = "auto" ]; then
    FORCE=""
elif [ -z "$FORCE" ]; then
    case "$DET" in
        1|2|6|243) FORCE="";  echo "    recognized type — no override needed";;
        *)         FORCE=6;   echo "    unrecognized type — forcing 0x06 (1-zone RGB)";;
    esac
fi

echo "==> persistent config (autoload + quirk)"
cat > /etc/modules-load.d/tuxedo-kbd.conf <<'EOF'
clevo_acpi
clevo_wmi
EOF
if [ -n "$FORCE" ]; then
    printf 'options tuxedo_keyboard force_clevo_kb_backlight_type=%s\n' "$FORCE" \
        > /etc/modprobe.d/tuxedo-kbd.conf
else
    rm -f /etc/modprobe.d/tuxedo-kbd.conf
fi

echo "==> reload with final settings"
modprobe -r tuxedo_io clevo_wmi clevo_acpi uniwill_wmi tuxedo_keyboard 2>/dev/null || true
[ -n "$FORCE" ] && modprobe tuxedo_keyboard "force_clevo_kb_backlight_type=$FORCE" || modprobe tuxedo_keyboard
modprobe clevo_acpi 2>/dev/null || true
modprobe clevo_wmi  2>/dev/null || true
sleep 1

echo
if [ -e "$LED/brightness" ]; then
    echo "✅ keyboard backlight is now controllable: $LED"
    echo "   next: sudo ./install.sh   (installs the kbdlight CLI + GUI)"
else
    echo "❌ $LED did not appear."
    echo "   Your firmware reported type ${DET_HEX:-unknown}. Try a different value:"
    echo "     sudo FORCE_TYPE=2 ./install-driver.sh   # 3-zone"
    echo "     sudo FORCE_TYPE=243 ./install-driver.sh # per-key"
    echo "   If none work, your laptop may use the Uniwill (not Clevo) interface — please open an issue."
fi
