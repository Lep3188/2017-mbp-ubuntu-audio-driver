#!/usr/bin/env bash
# doctor.sh - diagnose the MacBookPro14,3 (CS8409) audio stack.
#
#   ./scripts/doctor.sh          # read-only report
#   sudo ./scripts/doctor.sh --fix   # apply the safe fixes it can
#
# Exit status: 0 = no hard failure, 1 = at least one FAIL.
set -uo pipefail

FIX=0
[[ ${1:-} == "--fix" ]] && FIX=1

if [[ -t 1 ]]; then
    R=$'\033[1;31m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; B=$'\033[1;34m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; B=""; N=""
fi

FAILS=0
WARNS=0

pass() { printf '  %sPASS%s  %s\n' "$G" "$N" "$*"; }
warn() { printf '  %sWARN%s  %s\n' "$Y" "$N" "$*"; WARNS=$((WARNS+1)); }
fail() { printf '  %sFAIL%s  %s\n' "$R" "$N" "$*"; FAILS=$((FAILS+1)); }
section() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
hint() { printf '        %s\n' "$*"; }

USER_NAME=${SUDO_USER:-${USER:-$(id -un)}}

section "System"
printf '  kernel      : %s\n' "$(uname -r)"
printf '  distribution: %s\n' "$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || echo unknown)"
MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
printf '  model       : %s\n' "$MODEL"
if [[ $MODEL == "MacBookPro14,3" ]]; then
    pass "this is the machine this driver targets"
else
    warn "driver is tuned for MacBookPro14,3; this is '$MODEL'"
fi

section "Codec"
CODEC_FILES=(/proc/asound/card*/codec#*)
CODEC_FILE=""
for f in "${CODEC_FILES[@]}"; do
    if grep -q 'Cirrus Logic CS8409' "$f" 2>/dev/null; then CODEC_FILE=$f; break; fi
done
if [[ -n $CODEC_FILE ]]; then
    SSID=$(awk '/Subsystem Id/ {print $NF; exit}' "$CODEC_FILE")
    pass "CS8409 codec present ($CODEC_FILE, subsystem $SSID)"
    if [[ $SSID == "0x106b3900" ]]; then
        pass "subsystem ID matches MacBookPro14,3"
    else
        warn "subsystem ID $SSID is not 0x106b3900 (14,3)"
    fi
else
    fail "no CS8409 codec in /proc/asound"
    hint "is snd_hda_intel loaded?  lsmod | grep snd_hda_intel"
fi

section "Driver"
KO=$(modinfo -n snd_hda_codec_cs8409 2>/dev/null || true)
if [[ -z $KO ]]; then
    fail "snd-hda-codec-cs8409 is not installed"
else
    printf '  module      : %s\n' "$KO"
    APPLE=0; INSPECT=1
    case "$KO" in
        *.zst) if command -v zstdcat >/dev/null 2>&1; then
                   zstdcat "$KO" 2>/dev/null | grep -aq cs8409_apple && APPLE=1
               else INSPECT=0; fi ;;
        *.xz)  if command -v xzcat >/dev/null 2>&1; then
                   xzcat "$KO" 2>/dev/null | grep -aq cs8409_apple && APPLE=1
               else INSPECT=0; fi ;;
        *)     grep -aq cs8409_apple "$KO" 2>/dev/null && APPLE=1 ;;
    esac
    if ((APPLE)); then
        pass "Apple CS8409 code is present in the installed module"
    elif ((INSPECT == 0)); then
        warn "cannot inspect the compressed module (install zstd); check dmesg instead"
    else
        fail "the installed module is the stock (Dell-only) driver"
        hint "install with: sudo ./install.sh"
    fi
    if [[ $KO == */updates/* ]]; then
        pass "module is in updates/ (takes priority over the stock module)"
    else
        warn "module is not in an updates/ directory"
    fi
fi

if [[ -d /sys/module/snd_hda_codec_cs8409 ]]; then
    pass "snd_hda_codec_cs8409 is loaded"
else
    fail "snd_hda_codec_cs8409 is not loaded"
    hint "sudo modprobe snd_hda_codec_cs8409   (or reboot after installing)"
fi

# dmesg is often restricted; degrade quietly.
LOG=$( (journalctl -k -b --no-pager 2>/dev/null || dmesg 2>/dev/null) | grep -i -E 'cs8409|hdaudio' || true )
if [[ -n $LOG ]]; then
    if grep -q 'trying APPLE\|Post Patching for CS8409 Apple\|cs_8409_boot_setup' <<<"$LOG"; then
        pass "kernel log shows the Apple initialisation path running"
    elif grep -q 'autoconfig for CS8409' <<<"$LOG"; then
        fail "kernel log only shows generic autoconfig (Apple path not used)"
        hint "the installed module is probably still the stock one, or the old module is in the initramfs"
    fi
fi

section "Device nodes"
if [[ -d /dev/snd ]]; then
    pass "/dev/snd exists"
    if [[ -e /dev/snd/controlC0 ]]; then
        pass "/dev/snd/controlC0 exists"
    else
        warn "/dev/snd exists but controlC0 is missing"
    fi
else
    fail "/dev/snd is missing - ALSA cannot open any card"
    hint "sudo udevadm trigger --action=add --subsystem-match=sound"
    hint "if that does not create it, reboot; a container/chroot needs /dev/snd passed through"
fi

if id -nG "$USER_NAME" 2>/dev/null | tr ' ' '\n' | grep -qx audio; then
    pass "user $USER_NAME is in the audio group"
else
    warn "user $USER_NAME is not in the audio group"
    hint "sudo usermod -aG audio $USER_NAME   (then log out/in)"
fi

section "ALSA"
if command -v aplay >/dev/null 2>&1; then
    LIST=$(aplay -l 2>&1 || true)
    if grep -q 'CS8409' <<<"$LIST"; then
        pass "aplay sees the CS8409 analog device"
        grep 'CS8409' <<<"$LIST" | sed 's/^/        /'
    else
        fail "aplay does not see a CS8409 card"
        hint "$(head -n1 <<<"$LIST")"
    fi
else
    warn "alsa-utils is not installed (aplay/speaker-test missing)"
    hint "sudo apt install alsa-utils"
fi

section "Sound server"
if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
    pass "PipeWire/PulseAudio is running ($(pactl info | awk -F': ' '/Server Name/{print $2; exit}'))"
    SINKS=$(pactl list sinks short 2>/dev/null || true)
    if grep -q 'analog-stereo' <<<"$SINKS"; then
        pass "an analog-stereo sink is available"
    else
        warn "no analog-stereo sink (HDMI may be the only output)"
    fi
    printf '  default sink: %s\n' "$(pactl get-default-sink 2>/dev/null || echo unknown)"
else
    warn "PipeWire/PulseAudio is not reachable for this user"
    hint "log in to the graphical session, then re-run"
fi

section "Secure Boot"
if command -v mokutil >/dev/null 2>&1; then
    SB=$(mokutil --sb-state 2>/dev/null | head -n1 || true)
    printf '  %s\n' "${SB:-unknown}"
    case "$SB" in
        *enabled*)
            if [[ -n ${KO:-} ]]; then
                SIG=$(modinfo -F sig_id "$KO" 2>/dev/null || true)
                if [[ -n $SIG ]]; then pass "module is signed"; else
                    fail "Secure Boot is on but the module is unsigned - it will not load"
                    hint "sudo update-secureboot-policy --enroll-key   (then reboot and enrol in MOK manager)"
                fi
            fi ;;
        *disabled*) pass "Secure Boot is disabled or not enforcing" ;;
        *) warn "could not determine Secure Boot state" ;;
    esac
else
    warn "mokutil not installed; cannot check Secure Boot"
fi

section "Old workarounds"
if grep -rqs 'model=mbp101' /etc/modprobe.d/; then
    warn "model=mbp101 is set in /etc/modprobe.d (wrong quirk for CS8409)"
    hint "sudo ./install.sh disables it, or comment the line manually"
else
    pass "no obsolete model=mbp101 quirk"
fi

# ---------------------------------------------------------------------------
# fixes
# ---------------------------------------------------------------------------
if ((FIX)); then
    head "Applying safe fixes"
    [[ $EUID -eq 0 ]] || { warn "--fix needs root (sudo)"; }
    if [[ $EUID -eq 0 ]]; then
        if ! id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx audio; then
            usermod -aG audio "$USER_NAME" && pass "added $USER_NAME to audio"
            hint "log out and back in for the group change to apply"
        fi
        udevadm trigger --action=add --subsystem-match=sound 2>/dev/null || true
        for conf in /etc/modprobe.d/*.conf; do
            [[ -f $conf ]] || continue
            if grep -Eq '^[[:space:]]*options[[:space:]]+snd-hda-intel.*model=mbp101' "$conf"; then
                cp -a "$conf" "$conf.bak-$(date +%Y%m%d%H%M%S)"
                sed -i -E 's|^([[:space:]]*options[[:space:]]+snd-hda-intel.*model=mbp101.*)$|# disabled by mbp143-audio: \1|' "$conf"
                pass "disabled model=mbp101 in $conf"
            fi
        done
    fi
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
section "Summary"
if ((FAILS == 0)); then
    printf '  %sNo hard failures%s (%d warning(s)).\n' "$G" "$N" "$WARNS"
else
    printf '  %s%d failure(s)%s, %d warning(s).\n' "$R" "$FAILS" "$N" "$WARNS"
fi
echo "  Next: ./scripts/verify.sh          (post-reboot check)"
echo "        ./scripts/set-default-output.sh  (select the analog speakers)"
exit $((FAILS > 0 ? 1 : 0))
