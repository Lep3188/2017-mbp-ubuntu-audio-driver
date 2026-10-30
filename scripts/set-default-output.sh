#!/usr/bin/env bash
# set-default-output.sh - select the MacBook's analog speakers (and optionally
# the internal microphone) as the PipeWire/PulseAudio default.
#
#   ./scripts/set-default-output.sh          # speakers only
#   ./scripts/set-default-output.sh --duplex # speakers + internal mic
set -euo pipefail

DUPLEX=0
if [[ ${1:-} == "--duplex" ]]; then DUPLEX=1; fi

command -v pactl >/dev/null 2>&1 || {
    echo "error: pactl not found (install pipewire-pulse or pulseaudio-utils)" >&2
    exit 1
}
pactl info >/dev/null 2>&1 || {
    echo "error: no running PipeWire/PulseAudio session for this user" >&2
    exit 1
}

CARD=$(pactl list cards short 2>/dev/null | awk '$2 ~ /pci-0000_00_1f\.3/ {print $2; exit}')
if [[ -z $CARD ]]; then
    CARD=$(pactl list cards short 2>/dev/null | awk 'NR==1 {print $2}')
fi
[[ -n $CARD ]] || { echo "error: no sound card found by PipeWire" >&2; exit 1; }

PROFILES=$(pactl list cards 2>/dev/null \
    | awk '/^[[:space:]]*(output|input|pro-audio):/ { n=$1; sub(/:$/, "", n); print n }' \
    | sort -u)

choose_profile() {
    if ((DUPLEX)); then
        grep -qx 'output:analog-stereo+input:analog-stereo' <<<"$PROFILES" \
            && echo 'output:analog-stereo+input:analog-stereo' && return
    fi
    grep -qx 'output:analog-stereo' <<<"$PROFILES" && echo 'output:analog-stereo' && return
    grep -q 'analog-stereo' <<<"$PROFILES" && grep 'analog-stereo' <<<"$PROFILES" | head -n1 && return
    echo ""
}

PROFILE=$(choose_profile)
[[ -n $PROFILE ]] || { echo "error: card $CARD has no analog-stereo profile" >&2; exit 1; }

pactl set-card-profile "$CARD" "$PROFILE"
echo "card    : $CARD"
echo "profile : $PROFILE"

SINK=$(pactl list sinks short 2>/dev/null | awk '/analog-stereo/ {print $2; exit}')
if [[ -n $SINK ]]; then
    pactl set-default-sink "$SINK"
    echo "sink    : $SINK"
fi

if ((DUPLEX)); then
    SOURCE=$(pactl list sources short 2>/dev/null | awk '/analog-stereo/ {print $2; exit}')
    if [[ -n $SOURCE ]]; then
        pactl set-default-source "$SOURCE"
        echo "source  : $SOURCE"
    fi
fi

echo
echo "Done. Play something; if it is still silent, run ./scripts/doctor.sh."
