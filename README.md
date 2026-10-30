# 2017 macbook pro  audio

**Linux audio for the 2017 15-inch MacBook Pro (MacBookPro14,3) — and other
Cirrus Logic CS8409 Macs.**

The stock Linux kernel can see this machine's CS8409 HDA codec, creates a
sound card, and happily plays audio into it — but the speakers stay silent.
The missing piece is Apple's codec/amplifier initialisation, which is not in
the mainline driver. This package adds it, builds it against your running
kernel, and installs it without touching the kernel image.

```
        stock driver                         this package
  ┌───────────────────────┐          ┌───────────────────────────┐
  │ CS8409 + generic HDA  │          │ CS8409 + Apple init       │
  │ autoconfig            │          │  • pin 0x24/0x25 → amps   │
  │  ✗ amps never powered │          │  • I2C amp programming    │
  │  ✗ silence            │          │  • CS42L83 headset codec  │
  └───────────────────────┘          └───────────────────────────┘
```

## Status

| Item | State |
|---|---|
| Hardware target | MacBookPro14,3 (15", 2017), codec SSID `0x106b3900` |
| Kernel | Linux ≥ 6.17 (`sound/hda` layout); build-tested on Ubuntu 26.04, `7.0.0-28-generic` |
| Output | Internal speakers and headphones |
| Input | Internal mic and headset mic work, but the recorded level is low (see limitations) |
| Secure Boot | Supported via DKMS MOK signing; see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |
| Package version | 1.0.0 |

The driver is the long-standing community `snd_hda_macbookpro` code
(David Joseph, GPL-2.0), repackaged for the 6.17+ kernel source layout with a
new installer, DKMS integration, diagnostics and documentation. See
[Credits](#credits).

## Quick start

```bash
# 1. dependencies
BASE=$(uname -r | cut -d- -f1)
sudo apt install build-essential dkms linux-headers-$(uname -r) linux-source-$BASE

# 2. from this directory
sudo ./install.sh

# 3. reboot (the codec has to be re-probed)
sudo reboot

# 4. after logging back in, select and test the speakers
./scripts/set-default-output.sh
./scripts/verify.sh --tone
```

In **Settings → Sound**, the output should be **Analog Stereo Output**
(or **Analog Stereo Duplex** if you want the internal microphone).

## Requirements

- A Mac with a **Cirrus Logic CS8409** HDA codec. `MacBookPro14,3` is the
  primary target; the driver also carries quirks for MacBookPro14,1/14,2/13,x
  and iMac18,x, but those are not validated by this package.
- Linux **6.17 or newer**. Older kernels use a different source layout and
  are not supported by this tree.
- Kernel **headers** and kernel **source**:
  - Ubuntu/Debian: `linux-headers-$(uname -r)` and `linux-source-<base>`
    (for 7.0.0-28-generic that is `linux-source-7.0.0`).
  - Fedora: `kernel-devel` plus the matching kernel source.
  - Arch: the matching `linux-headers` and kernel source package.
- `dkms` is strongly recommended: it rebuilds the module automatically after
  every kernel update.

The headers alone are not enough. The Apple code is not a standalone module —
it is the kernel's own `snd-hda-codec-cs8409` driver plus extra initialisation,
so the build needs the kernel's `sound/hda` sources.

## Install options

```bash
sudo ./install.sh                # DKMS if available, otherwise one-shot
sudo ./install.sh --dkms         # force DKMS
sudo ./install.sh --no-dkms      # install only for the running kernel
sudo ./install.sh --kernel 7.0.0-28-generic
sudo ./install.sh --source /path/to/linux   # use an extracted kernel tree
sudo ./install.sh --download     # fetch the kernel tarball if it is missing
./install.sh --build-only DIR    # unprivileged build, nothing is installed
sudo ./install.sh --force        # skip the model sanity check
sudo ./uninstall.sh              # restore the stock module
```

The installer:

1. checks the machine, codec, headers and kernel source;
2. copies the kernel's `sound/hda` tree into a private build directory;
3. grafts the Apple codec/amplifier code onto `cs8409.c`/`cs8409.h`;
4. builds `snd-hda-codec-cs8409.ko` against your exact kernel;
5. installs it under `updates/`, so it takes priority over the stock module;
6. runs `depmod` and refreshes the initramfs;
7. disables the obsolete `model=mbp101` quirk if it finds it;
8. reports whether Secure Boot will accept the module.

Nothing in `/boot` or the kernel package is modified, and uninstalling
restores the stock driver.

## Verify

```bash
./scripts/doctor.sh        # full diagnosis, PASS/WARN/FAIL
./scripts/verify.sh        # card + driver + mixer checks
./scripts/verify.sh --tone # also plays a short 440 Hz tone (LOUD)
```

Expected signs of success:

```bash
$ aplay -l | grep CS8409
card 0: PCH [HDA Intel PCH], device 0: CS8409 Analog [CS8409 Analog]

$ sudo dmesg | grep -i 'cs8409.*apple'
snd_hda_intel: Primary patch_cs8409 NOT FOUND trying APPLE
snd_hda_intel: Post Patching for CS8409 Apple
```

## Why the stock driver is silent

The CS8409 is not a normal HDA codec with built-in amplifiers. It is a bridge:
audio arrives over HDA, is converted to TDM, and is sent to external speaker
amplifiers (TAS5764L-class) and to a CS42L83 headset codec. Those chips are
programmed through undocumented vendor coefficient/I2C writes on HDA node
`0x47`.

Mainline `snd-hda-codec-cs8409` only knows the Dell laptops in its quirk table
(`0x1028:...`). On an Apple machine no quirk matches, so the driver falls back
to generic HDA autoconfig. That configures the HDA pins and creates a working
PCM device, which is why `aplay` succeeds and the volume slider moves — but
the amplifiers are never powered or configured, so the speakers emit nothing.

This package makes the Apple subsystem ID a first-class case: when no stock
quirk matches, it jumps into an Apple-specific probe that validates the
subsystem ID, applies the MacBook pin configuration, builds the PCMs with the
format Apple's hardware expects, and replays the macOS-derived initialisation
sequence (including the amplifier I2C writes).

See [docs/TECHNICAL.md](docs/TECHNICAL.md) for the call flow and the exact
HDA/I2C details.

## Kernel updates

With DKMS the module is rebuilt automatically for each new kernel. After a
kernel update, check:

```bash
dkms status | grep mbp143
./scripts/doctor.sh
```

Without DKMS, re-run `sudo ./install.sh --no-dkms` after every kernel update.

## Secure Boot

Ubuntu and Fedora will refuse to load an unsigned kernel module when Secure
Boot is enabled. DKMS signs modules with a Machine Owner Key (MOK), but the key
has to be enrolled once:

```bash
sudo update-secureboot-policy --enroll-key   # Debian/Ubuntu
sudo reboot
# in the blue MOK manager: Enroll MOK → Continue → Yes → reboot
```

`./scripts/doctor.sh` tells you whether your current module is signed and
whether Secure Boot will accept it. Alternatively, disable Secure Boot in the
firmware. Full details in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Known limitations

- The hardware path is fixed at **44.1 kHz, 24-bit, 4-channel** (two speaker
  pairs). PipeWire resamples transparently; the raw `hw:` device does not, and
  it also has **no volume control** — `plughw:`/PipeWire is strongly advised.
- The Apple CoreAudio digital filters (tweeter/woofer crossover and EQ) are not
  reproduced. All four speakers are driven, but the tonal balance differs from
  macOS. Channel order is tweeter L/R then woofer L/R.
- Recording works but the level is low; that is the level macOS receives too.
  Apply gain in PipeWire/PulseEffects if needed.
- Suspend/resume and power management are not fully validated.
- Only the CS8409 + external-amplifier machines are supported; this is not a
  generic HDA fix.

## Project layout

```
mbp143-audio/
├── install.sh                 # build + install (DKMS or one-shot)
├── uninstall.sh               # remove and restore the stock module
├── dkms.conf                  # DKMS package definition
├── src/
│   ├── apple/                 # Apple codec/amplifier init code
│   ├── makefiles/             # minimal kbuild makefiles
│   └── patches/               # cs8409.c / cs8409.h integration patches
├── scripts/
│   ├── prepare-source.sh      # kernel source acquisition + graft + build
│   ├── doctor.sh              # diagnosis
│   ├── verify.sh              # post-reboot verification
│   └── set-default-output.sh  # select the analog speakers in PipeWire
└── docs/
    ├── TECHNICAL.md
    └── TROUBLESHOOTING.md
```

## Credits

This package is a repackaging of the excellent
[`davidjo/snd_hda_macbookpro`](https://github.com/davidjo/snd_hda_macbookpro)
driver by **David Joseph** and contributors, which reverse-engineered Apple's
codec initialisation. The Apple verb/I2C tables originate from macOS
`AppleHDA.kext` traces. The 6.17+ build approach follows the upstream patches.

The packaging, 7.0 kernel verification, installer, DKMS integration and
diagnostics are new work released under the same licence.

Licensed under the **GNU General Public License v2.0** (see [LICENSE](LICENSE)).
`src/apple/` and `src/patches/` retain their original copyright and licence.
