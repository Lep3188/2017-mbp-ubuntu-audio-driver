#!/usr/bin/env bash
# DKMS PRE_BUILD hook: prepare the kernel source tree inside the DKMS build
# directory. Invoked by dkms.conf with the target kernel release.
set -euo pipefail

KVER=${1:-${kernelver:-$(uname -r)}}
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

exec "$HERE/scripts/prepare-source.sh" --kernel "$KVER" --dest "$HERE/build"
