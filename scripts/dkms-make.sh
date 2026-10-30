#!/usr/bin/env bash
# DKMS MAKE hook. DKMS runs this from the copied source directory.
set -euo pipefail

KVER=${1:-${kernelver:-$(uname -r)}}
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
HEADERS=/lib/modules/$KVER/build
KCFLAGS="-DAPPLE_PINSENSE_FIXUP -DAPPLE_CODECS -DCONFIG_SND_HDA_RECONFIG=1 -Wno-unused-variable -Wno-unused-function"

[[ -d $HERE/build/hda ]] || {
    echo "dkms-make: $HERE/build/hda is missing (PRE_BUILD did not run)" >&2
    exit 1
}

exec make -C "$HEADERS" M="$HERE/build/hda" CFLAGS_MODULE="$KCFLAGS" \
    -j"$(nproc)" modules
