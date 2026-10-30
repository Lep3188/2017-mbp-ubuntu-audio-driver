# Troubleshooting

Start with the diagnosis script — it checks all of the below and prints a
PASS/WARN/FAIL line for each item:

```bash
./scripts/doctor.sh
```

## Quick decision tree

```
aplay -l shows "CS8409 Analog"?
├─ no  → 1. Card not created
└─ yes → Is sound coming out of the internal speakers?
         ├─ no  → 2. Card exists but silent
         └─ yes → 4. Sound works, but quality/format issues
```

## 1. Card not created

### 1.1 Is the module installed and the Apple one?

```bash
modinfo -n snd_hda_codec_cs8409
# should contain /updates/
modinfo snd_hda_codec_cs8409 | head
sudo dmesg | grep -i cs8409
```

If the path is `/lib/modules/.../kernel/sound/hda/...` the stock module is
still being selected. Re-run `sudo ./install.sh`, then `sudo depmod -a` and
reboot.

### 1.2 Is it loaded?

```bash
lsmod | grep snd_hda
sudo modprobe snd_hda_codec_cs8409
```

A missing `snd_hda_intel` usually means the HDA controller was not bound.
Check `lspci -nn | grep -i audio` and `sudo dmesg | grep -i hda`.

### 1.3 Secure Boot rejected it

```bash
sudo dmesg | grep -i -E 'module verification|PKCS#7|Lockdown'
mokutil --sb-state
modinfo -F sig_id "$(modinfo -n snd_hda_codec_cs8409)"
```

If Secure Boot is enabled and `sig_id` is empty, the module is unsigned and
will not load:

```bash
sudo update-secureboot-policy --enroll-key   # Debian/Ubuntu, dkms MOK
sudo reboot
# blue MOK manager: Enroll MOK → Continue → Yes → reboot
```

Or disable Secure Boot in the firmware. Some systems need the key enrolled
via `mokutil --import /var/lib/dkms/mok.pem` instead; use whatever key your
DKMS installation generated.

### 1.4 /dev/snd is missing

ALSA cannot open a card without device nodes. `doctor.sh` checks this.

```bash
ls -la /dev/snd
sudo udevadm trigger --action=add --subsystem-match=sound
```

If `/dev` is not a devtmpfs (container, chroot, broken fstab), the nodes will
not appear; pass `/dev/snd` through from the host or fix the `/dev` mount.
A normal reboot also recreates them.

### 1.5 An older `snd_hda_macbookpro` checkout is installed

Checkouts from before 2026 target `sound/pci/hda` (kernels up to 6.16). On
6.17+ they fail with errors such as `No rule to make target
'sound/pci/hda/...'`, or they build a module that never loads. Remove any
leftover module before installing this package:

```bash
sudo rm -f /lib/modules/"$(uname -r)"/updates/snd-hda-codec-cs8409.ko
sudo rm -f /lib/modules/"$(uname -r)"/updates/dkms/snd-hda-codec-cs8409.ko*
sudo depmod -a
sudo ./install.sh
```

Also remove old DKMS registrations (`dkms status`) if they refer to
`snd_hda_macbookpro`.

### 1.6 Kernel source/headers mismatch

The installer refuses to run without matching sources. On Ubuntu the base
version matters: `7.0.0-28-generic` needs `linux-source-7.0.0`, not
`linux-source-7.0.0-28`. HWE kernels often have no matching source package;
boot a GA kernel or use the distribution's kernel source tree with
`--source /path/to/linux`.

## 2. Card exists but the speakers are silent

### 2.1 Wrong PipeWire profile

```bash
./scripts/set-default-output.sh
pactl list cards short
pactl get-default-sink
```

The output must be **Analog Stereo Output** (or **Analog Stereo Duplex**), not
HDMI and not "Pro Audio". In GNOME: Settings → Sound → Output → *Analog
Stereo Output*.

If HDMI is the default because a monitor is plugged in, select the internal
speakers explicitly — this is a PipeWire policy issue, not a driver issue.

### 2.2 Muted or zero volume

```bash
amixer -c 0 scontrols
amixer -c 0 sget Master
pactl list sinks | grep -E 'Mute|Volume' | head
```

Unmute and raise the volume. Remember that the raw `hw:` device has no volume
control; use the PipeWire sink.

### 2.3 Is this really an Apple 8409 machine?

```bash
cat /sys/class/dmi/id/product_name
grep -H 'Subsystem Id' /proc/asound/card*/codec#*
```

The driver only initialises the amplifier path for known Apple subsystem IDs.
An unknown ID returns `-ENODEV` and the card will not be created at all
(check `dmesg` for `UNKNOWN subsystem id`).

### 2.4 The Apple path did not run

```bash
sudo dmesg | grep -i -E 'trying APPLE|Post Patching for CS8409 Apple'
```

If neither line appears, the stock module was loaded. This can happen if the
initramfs still contains the old module:

```bash
sudo update-initramfs -u -k "$(uname -r)"
sudo reboot
```

### 2.5 Old `model=mbp101` quirk

`model=mbp101` is a CS420x quirk that circulated in MacBook audio guides. It
does nothing for CS8409. `install.sh` comments it out; to check manually:

```bash
grep -rn 'mbp101' /etc/modprobe.d/
```

### 2.6 Headphones work, speakers do not (or vice versa)

The speaker and headphone paths are separate amplifier/CS42L83 paths. Check
the jack detection lines in `dmesg`, and make sure nothing is physically in
the headphone jack. Report both behaviours in a bug report — they narrow down
which part of the init sequence is failing.

## 3. DKMS problems

```bash
dkms status
dkms status -m mbp143-audio -v 1.0.0
```

Common causes:

* **`dkms` not installed** — install it, then `sudo ./install.sh --dkms`.
* **build fails after a kernel update** — the new kernel's `sound/hda` layout
  or API changed. Check `/var/lib/dkms/mbp143-audio/1.0.0/build/make.log`,
  then re-run the installer (it may need an updated patch set).
* **module not rebuilt** — `sudo dkms autoinstall`.
* **stale source** — `sudo ./uninstall.sh && sudo ./install.sh`.

DKMS keeps a copy of the source in `/usr/src/mbp143-audio-1.0.0`; removing
that directory without `dkms remove` leaves a broken registration.

## 4. Sound works, but quality/format issues

* **Crackling or resampling artefacts** — the amp path is fixed at 44.1 kHz.
  Let PipeWire resample; avoid `hw:` and set the default sink to the
  `analog-stereo` PipeWire sink. You can also force PipeWire's default rate
  to 44100 in `~/.config/pipewire/pipewire.conf.d/`.
* **No bass / different tonal balance** — expected. macOS applies a crossover
  and EQ for the tweeter/woofer pairs in CoreAudio; this driver drives all
  four speakers but does not reproduce those filters.
* **Volume jumps or is very loud** — the amps run at a fixed gain. Use the
  PipeWire sink, not the raw hardware device, and keep the sink volume low
  for the first test.
* **Low microphone level** — known limitation; the CS42L83 returns the same
  low level to macOS. Apply gain in PipeWire/PulseEffects.
* **Suspend/resume** — not fully validated. If audio dies after resume,
  reloading the module (`sudo modprobe -r snd_hda_codec_cs8409; sudo modprobe
  snd_hda_codec_cs8409`) is a workaround; please report it.

## 5. Uninstall / restore the stock driver

```bash
sudo ./uninstall.sh
sudo reboot
```

This removes the DKMS registration and the `updates/` module and refreshes
`depmod`/initramfs. The kernel's own module was never overwritten, so it
becomes active again.

## 6. Reporting a bug

Please include:

```bash
uname -a
cat /sys/class/dmi/id/product_name
grep -H 'Subsystem Id' /proc/asound/card*/codec#*
dkms status
modinfo -n snd_hda_codec_cs8409
sudo dmesg | grep -i -E 'cs8409|hda|snd' | tail -100
./scripts/doctor.sh
```

and a short description of what you hear (nothing / only headphones / only
one side / distorted).
