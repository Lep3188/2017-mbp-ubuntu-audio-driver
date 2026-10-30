#!/usr/bin/env bash
# smoke-test.sh - build the driver from a clean tree and check the artifact.
#
#   ./tests/smoke-test.sh [OUTPUT_DIR]
#
# Needs the kernel headers and kernel source, but no root: it exercises the
# same prepare/build path as install.sh without touching /lib/modules.
set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${1:-$REPO/build-smoke}
KVER=$(uname -r)

echo "==> clean build for $KVER in $OUT"
rm -rf "$OUT"
"$REPO/install.sh" --build-only "$OUT" >/dev/null

KO=$OUT/hda/codecs/cirrus/snd-hda-codec-cs8409.ko
[[ -f $KO ]] || { echo "FAIL: module was not produced" >&2; exit 1; }
echo "  ok  module exists"

VM=$(modinfo -F vermagic "$KO")
case "$VM" in
    "$KVER "*) echo "  ok  vermagic: $VM" ;;
    *) echo "FAIL: vermagic '$VM' does not match running kernel $KVER" >&2; exit 1 ;;
esac

ALIAS=$(modinfo -F alias "$KO")
grep -q 'hdaudio:v10138409' <<<"$ALIAS" \
    || { echo "FAIL: missing hdaudio alias" >&2; exit 1; }
echo "  ok  codec modalias: $ALIAS"

grep -aq 'cs8409_apple' "$KO" \
    || { echo "FAIL: Apple code was not linked in" >&2; exit 1; }
echo "  ok  Apple initialisation code present"

for sym in cs_8409_boot_setup_data cs_8409_boot_setup_data_ssm3; do
    grep -aq "$sym" "$KO" || { echo "FAIL: missing $sym" >&2; exit 1; }
done
echo "  ok  amplifier boot tables present"

echo
echo "Smoke test passed: $KO"
