#!/usr/bin/env bash
# uninstall.sh - remove the Apple CS8409 driver and restore the stock module.
set -euo pipefail

NAME="mbp143-audio"
VERSION="1.0.0"
KVER=$(uname -r)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "uninstall needs root. Re-run with: sudo $0"

if command -v dkms >/dev/null 2>&1 && dkms status -m "$NAME" -v "$VERSION" 2>/dev/null | grep -q .; then
    info "removing $NAME/$VERSION from DKMS"
    dkms remove -m "$NAME" -v "$VERSION" --all || true
fi

if [[ -d /usr/src/$NAME-$VERSION ]]; then
    info "removing /usr/src/$NAME-$VERSION"
    rm -rf "/usr/src/$NAME-$VERSION"
fi

# Direct (non-DKMS) installs land here.
DIRECT=/lib/modules/$KVER/updates/codecs/cirrus/snd-hda-codec-cs8409.ko
if [[ -e $DIRECT ]]; then
    info "removing $DIRECT"
    rm -f "$DIRECT"
fi
if [[ -d /var/lib/$NAME ]]; then
    rm -rf "/var/lib/$NAME"
fi

depmod -a "$KVER"
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u -k "$KVER" >/dev/null 2>&1 || true
fi

ok "removed. The stock kernel module will be used after the next reboot."
echo "Reboot to return to the unmodified driver."
