#!/usr/bin/env bash
# install.sh - build and install the Apple CS8409 audio driver.
#
#   sudo ./install.sh                 # DKMS if available, else one-shot
#   sudo ./install.sh --dkms          # force DKMS
#   sudo ./install.sh --no-dkms       # one-shot (re-run after kernel updates)
#   sudo ./install.sh --source DIR    # use an already extracted kernel tree
#   sudo ./install.sh --download      # fetch the kernel tarball if missing
#   sudo ./install.sh --kernel VER    # target a non-running kernel
#   sudo ./install.sh --uninstall     # remove everything
#   ./install.sh --build-only DIR     # unprivileged build, installs nothing
#
# The one-shot path is useful on systems without dkms; DKMS is preferred
# because it rebuilds the module automatically for new kernels.
set -euo pipefail

NAME="mbp143-audio"
VERSION="1.0.0"
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KVER=$(uname -r)
MODE="auto"           # auto | dkms | direct
BUILD_ONLY=""
FORCE=0
SOURCE_TREE=""
ALLOW_DOWNLOAD=0

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! \033[0m%s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next }
         NR > 1 { exit }' "$0"
    exit 0
}

while (($#)); do
    case "$1" in
        -k|--kernel)   KVER=${2:?}; shift 2 ;;
        --dkms)        MODE="dkms"; shift ;;
        --no-dkms)     MODE="direct"; shift ;;
        --build-only)
            BUILD_ONLY=$REPO_DIR/build
            if (($# >= 2)) && [[ $2 != -* ]]; then BUILD_ONLY=$2; shift; fi
            shift ;;
        --uninstall)   exec "$REPO_DIR/uninstall.sh" ;;
        --force)       FORCE=1; shift ;;
        --source)      SOURCE_TREE=${2:?}; shift 2 ;;
        --download)    ALLOW_DOWNLOAD=1; shift ;;
        -h|--help)     usage ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
# unprivileged build-only mode (used by CI and by the test suite)
# ---------------------------------------------------------------------------
if [[ -n $BUILD_ONLY ]]; then
    if [[ $EUID -eq 0 ]]; then warn "running as root; --build-only does not install anything"; fi
    mkdir -p "$BUILD_ONLY"
    BUILD_ONLY=$(cd -- "$BUILD_ONLY" && pwd)
    info "building driver for $KVER into $BUILD_ONLY"
    EXTRA=()
    [[ -n $SOURCE_TREE ]] && EXTRA+=(--source "$SOURCE_TREE")
    (( ALLOW_DOWNLOAD )) && EXTRA+=(--download)
    "$REPO_DIR/scripts/prepare-source.sh" --kernel "$KVER" --dest "$BUILD_ONLY" "${EXTRA[@]}"
    bold "Module built successfully:"
    echo "  $BUILD_ONLY/hda/codecs/cirrus/snd-hda-codec-cs8409.ko"
    exit 0
fi

[[ $EUID -eq 0 ]] || die "installation needs root. Re-run with: sudo $0 $*"

# ---------------------------------------------------------------------------
# machine check
# ---------------------------------------------------------------------------
MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
CODEC=$(grep -l 'Cirrus Logic CS8409' /proc/asound/card*/codec#* 2>/dev/null | head -n1 || true)

info "machine: $MODEL"
if [[ $(uname -r) != "$KVER" ]]; then
    info "target kernel: $KVER (running $(uname -r))"
fi

if [[ $MODEL != "MacBookPro14,3" ]]; then
    warn "this release is tuned for MacBookPro14,3; '$MODEL' is not that model."
    warn "It also carries quirks for MacBookPro14,1/14,2/13,x and iMac18,x,"
    warn "but those are untested here. Continuing anyway."
fi
if [[ -z $CODEC ]]; then
    warn "no CS8409 codec found in /proc/asound right now."
    warn "That is expected if snd_hda_intel is not loaded; install will continue."
else
    ok "CS8409 codec found ($CODEC)"
fi

# ---------------------------------------------------------------------------
# kernel source check (needed by both install modes)
# ---------------------------------------------------------------------------
BASE=${KVER%%-*}
if [[ -n $SOURCE_TREE ]]; then
    [[ -f $SOURCE_TREE/sound/hda/codecs/cirrus/cs8409.c ]] \
        || die "$SOURCE_TREE does not look like a Linux source tree (no sound/hda/codecs/cirrus/cs8409.c)"
elif [[ ! -e /usr/src/linux-source-$BASE.tar.bz2 && ! -e /usr/src/linux-source-$BASE.tar.xz \
      && ! -e /usr/src/linux-source-$BASE/linux-source-$BASE.tar.bz2 \
      && ! -f /usr/src/linux-source-$BASE/sound/hda/codecs/cirrus/cs8409.c \
      && ! -f /lib/modules/$KVER/build/sound/hda/codecs/cirrus/cs8409.c \
      && ! -f /lib/modules/$KVER/source/sound/hda/codecs/cirrus/cs8409.c ]]; then
    die "kernel source for $BASE not found.
  Ubuntu/Debian: sudo apt install linux-source-$BASE linux-headers-$KVER
  Fedora:        sudo dnf install kernel-devel
  Arch:          install the matching linux-source package

  (Headers alone are not enough: the driver is built from the kernel's own
   sound/hda helper code.)"
fi

# ---------------------------------------------------------------------------
# dkms vs direct
# ---------------------------------------------------------------------------
if [[ $MODE == "auto" ]]; then
    if command -v dkms >/dev/null 2>&1; then MODE="dkms"; else MODE="direct"; fi
fi
if [[ -n $SOURCE_TREE && $MODE == "dkms" ]]; then
    warn "a custom --source tree cannot be used by DKMS; using one-shot mode"
    MODE="direct"
fi
if [[ $MODE == "dkms" ]] && ! command -v dkms >/dev/null 2>&1; then
    warn "dkms is not installed; falling back to a one-shot install"
    warn "install dkms to survive kernel updates automatically"
    MODE="direct"
fi

SRC=/usr/src/$NAME-$VERSION

install_dkms() {
    info "installing DKMS source to $SRC"
    rm -rf "$SRC"
    mkdir -p "$SRC"
    cp -a "$REPO_DIR"/. "$SRC"/
    rm -rf "$SRC/.git" "$SRC/build" "$SRC/.cache"

    info "registering $NAME/$VERSION with DKMS"
    dkms remove -m "$NAME" -v "$VERSION" --all >/dev/null 2>&1 || true
    dkms add -m "$NAME" -v "$VERSION" >/dev/null

    info "building for $KVER (this can take a minute)"
    dkms build -m "$NAME" -v "$VERSION" -k "$KVER"

    info "installing module"
    dkms install --force -m "$NAME" -v "$VERSION" -k "$KVER"

    depmod -a "$KVER"
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u -k "$KVER" >/dev/null 2>&1 || true
    fi
}

install_direct() {
    local build=/var/lib/$NAME/build
    info "building driver for $KVER in $build"
    local extra=()
    [[ -n $SOURCE_TREE ]] && extra+=(--source "$SOURCE_TREE")
    (( ALLOW_DOWNLOAD )) && extra+=(--download)
    "$REPO_DIR/scripts/prepare-source.sh" --kernel "$KVER" --dest "$build" "${extra[@]}"

    local ko=$build/hda/codecs/cirrus/snd-hda-codec-cs8409.ko
    local dest=/lib/modules/$KVER/updates/codecs/cirrus
    info "installing to $dest"
    install -D -m 0644 "$ko" "$dest/snd-hda-codec-cs8409.ko"
    depmod -a "$KVER"
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u -k "$KVER" >/dev/null 2>&1 || true
    fi
}

if [[ $MODE == "dkms" ]]; then
    install_dkms
else
    install_direct
fi

# ---------------------------------------------------------------------------
# neutralise an old, wrong quirk
# ---------------------------------------------------------------------------
# model=mbp101 is a CS420x quirk. It does nothing useful for CS8409 and was
# historically copied into MacBook audio guides. Comment it out once.
for conf in /etc/modprobe.d/*.conf; do
    [[ -f $conf ]] || continue
    if grep -Eq '^[[:space:]]*options[[:space:]]+snd-hda-intel.*model=mbp101' "$conf"; then
        info "disabling obsolete 'model=mbp101' quirk in $conf"
        cp -a "$conf" "$conf.bak-$(date +%Y%m%d%H%M%S)"
        sed -i -E 's|^([[:space:]]*options[[:space:]]+snd-hda-intel.*model=mbp101.*)$|# disabled by mbp143-audio (CS8409 does not use mbp101): \1|' "$conf"
    fi
done

# ---------------------------------------------------------------------------
# device nodes / group membership
# ---------------------------------------------------------------------------
if getent group audio >/dev/null 2>&1 && [[ -n ${SUDO_USER:-} ]]; then
    if ! id -nG "$SUDO_USER" | tr ' ' '\n' | grep -qx audio; then
        usermod -aG audio "$SUDO_USER" && ok "added $SUDO_USER to the audio group (log out/in to apply)"
    fi
fi

if [[ ! -d /dev/snd ]]; then
    udevadm trigger --action=add --subsystem-match=sound 2>/dev/null || true
fi
if [[ ! -d /dev/snd ]]; then
    warn "/dev/snd is missing: ALSA cannot use the card until the device nodes exist."
    warn "Reboot; in a container/chroot, /dev/snd must be passed through from the host."
fi

# ---------------------------------------------------------------------------
# secure boot / signing report
# ---------------------------------------------------------------------------
KO_PATH=$(modinfo -n snd_hda_codec_cs8409 2>/dev/null || true)
SB_STATE="unknown"
if command -v mokutil >/dev/null 2>&1; then
    SB_STATE=$(mokutil --sb-state 2>/dev/null | head -n1 || true)
fi
if [[ $SB_STATE == *enabled* ]]; then
    if [[ -n $KO_PATH ]] && [[ -z $(modinfo -F sig_id "$KO_PATH" 2>/dev/null || true) ]]; then
        warn "Secure Boot is enabled and this module is NOT signed."
        warn "The module will be rejected at boot. Enrol a MOK key, for example:"
        warn "  sudo update-secureboot-policy --enroll-key"
        warn "or disable Secure Boot in the firmware. See docs/TROUBLESHOOTING.md."
    else
        ok "Secure Boot is enabled; module is signed."
    fi
fi

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------
bold ""
bold "Driver installed for $KVER ($MODE)."
echo
echo "Next steps:"
echo "  1. Reboot (the codec must be re-probed; a module reload is usually not enough)."
echo "  2. In Settings -> Sound choose 'Analog Stereo Output' (or 'Analog Stereo Duplex')."
echo "  3. Run ./scripts/doctor.sh to verify, then ./scripts/verify.sh to play a test tone."
echo
echo "Kernel updates:"
if [[ $MODE == "dkms" ]]; then
    echo "  DKMS will rebuild the module automatically."
else
    echo "  Re-run 'sudo ./install.sh --no-dkms' after each kernel update, or install dkms."
fi
echo
echo "Uninstall with: sudo ./uninstall.sh"
