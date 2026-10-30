#!/usr/bin/env bash
# DKMS CLEAN hook.
set -euo pipefail

KVER=${1:-${kernelver:-$(uname -r)}}
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
HEADERS=/lib/modules/$KVER/build

if [[ -d $HERE/build/hda ]]; then
    make -C "$HEADERS" M="$HERE/build/hda" clean >/dev/null 2>&1 || true
fi
exit 0
