#!/usr/bin/env bash
# verify.sh - post-install / post-reboot verification.
#
#   ./scripts/verify.sh          # checks only
#   ./scripts/verify.sh --tone   # also plays a short 440 Hz test tone (LOUD)
#
# This script never modifies the system.
set -uo pipefail

TONE=0
[[ ${1:-} == "--tone" ]] && TONE=1

if [[ -t 1 ]]; then
    R=$'\033[1;31m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; B=$'\033[1;34m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; B=""; N=""
fi
FAILS=0
pass() { printf '  %sPASS%s  %s\n' "$G" "$N" "$*"; }
fail() { printf '  %sFAIL%s  %s\n' "$R" "$N" "$*"; FAILS=$((FAILS+1)); }
warn() { printf '  %sWARN%s  %s\n' "$Y" "$N" "$*"; }
section() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
hint() { printf '        %s\n' "$*"; }

section "Card"
LIST=$(aplay -l 2>&1 || true)
if grep -q 'CS8409' <<<"$LIST"; then
    pass "CS8409 analog card is visible"
    grep 'CS8409' <<<"$LIST" | sed 's/^/        /'
    CARD=$(awk '/CS8409/ {gsub(":", "", $2); print $2; exit}' <<<"$LIST")
    DEV=$(awk '/CS8409/ {
        for (i = 1; i <= NF; i++)
            if ($i == "device") { gsub(":", "", $(i+1)); print $(i+1); exit }
    }' <<<"$LIST")
else
    fail "CS8409 card not visible"
    hint "reboot after installing, then check: ./scripts/doctor.sh"
    exit 1
fi

section "Kernel driver"
KO=$(modinfo -n snd_hda_codec_cs8409 2>/dev/null || true)
APPLE=0; INSPECT=1
case "$KO" in
    *.zst) if command -v zstdcat >/dev/null 2>&1; then
               zstdcat "$KO" 2>/dev/null | grep -aq cs8409_apple && APPLE=1
           else INSPECT=0; fi ;;
    *.xz)  if command -v xzcat >/dev/null 2>&1; then
               xzcat "$KO" 2>/dev/null | grep -aq cs8409_apple && APPLE=1
           else INSPECT=0; fi ;;
    "")    : ;;
    *)     grep -aq cs8409_apple "$KO" 2>/dev/null && APPLE=1 ;;
esac
if ((APPLE)); then
    pass "Apple driver module installed ($KO)"
elif ((INSPECT == 0)); then
    warn "cannot inspect the compressed module (install zstd); check dmesg instead"
else
    fail "stock (Dell-only) module installed"
fi

LOG=$( (journalctl -k -b --no-pager 2>/dev/null || dmesg 2>/dev/null) | grep -i 'cs8409' || true )
if grep -q 'Post Patching for CS8409 Apple\|trying APPLE' <<<"$LOG"; then
    pass "kernel log shows Apple codec initialisation"
else
    warn "no Apple initialisation marker in the kernel log"
    hint "the module may not have been loaded at boot; run: sudo modprobe -r snd_hda_codec_cs8409; sudo modprobe snd_hda_codec_cs8409"
fi

section "Mixer"
if command -v amixer >/dev/null 2>&1; then
    CTLS=$(amixer -c "$CARD" scontrols 2>/dev/null | wc -l)
    if ((CTLS > 0)); then
        pass "$CTLS mixer control(s) on card $CARD"
    else
        warn "no mixer controls reported (the amp is fixed-volume; this can be normal)"
    fi
fi

section "Playback"
if ((TONE)); then
    command -v speaker-test >/dev/null 2>&1 || {
        fail "speaker-test is missing (sudo apt install alsa-utils)"
    }
    if command -v speaker-test >/dev/null 2>&1; then
        echo "  Playing 440 Hz for a few seconds. This is LOUD - press Ctrl+C to stop."
        speaker-test -D "plughw:CARD=$CARD,DEV=$DEV" -c 2 -t sine -f 440 -l 1 || \
            fail "speaker-test failed (see the error above)"
        pass "tone finished without an ALSA error"
    fi
else
    warn "tone not played (pass --tone to test the speakers)"
fi

section "Result"
if ((FAILS == 0)); then
    printf '  %sAudio stack looks healthy.%s\n' "$G" "$N"
    echo "  If you still hear nothing:"
    echo "    ./scripts/set-default-output.sh   # pick the analog speakers in PipeWire"
    echo "    docs/TROUBLESHOOTING.md"
    exit 0
else
    printf '  %s%d check(s) failed.%s\n' "$R" "$FAILS" "$N"
    echo "  Run ./scripts/doctor.sh for the full picture."
    exit 1
fi
