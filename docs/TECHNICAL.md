# Technical notes

## 1. The machine

| | |
|---|---|
| Model | MacBook Pro 15-inch, 2017 (`MacBookPro14,3`) |
| CPU | Intel Core i7-7820HQ (Kaby Lake-H) |
| HDA controller | Intel `8086:a170` (100/C230 series), PCI `00:1f.3` |
| Codec | Cirrus Logic **CS8409** HDA bridge, vendor ID `0x10138409` |
| Codec subsystem ID | `0x106b3900` (Apple) |
| Speaker amplifiers | external I2S/TDM amps (TAS5764L-class) |
| Headset codec | Cirrus Logic **CS42L83** |
| HDMI audio | AMD Baffin `1002:aae0` (separate card, unaffected) |

The 2017 15-inch board has four speakers wired as two stereo pairs: left
tweeter + left woofer, right tweeter + right woofer. The CS8409 does not
amplify anything itself. It takes HDA PCM, converts it to a TDM stream, and
ships it over two audio serial ports:

```
HDA PCM  ──►  CS8409  ──ASP1──►  speaker amps (4 channels)
                       └─ASP2──►  CS42L83 (headset DAC/ADC + jack detect)
```

Both the amps and the CS42L83 are configured through **vendor node `0x47`**
using coefficient-index / coefficient-data verbs. That is an undocumented
I2C bridge inside the codec; there is no Linux I2C device for it and no
standard HDA widget for the amplifiers.

## 2. Why the stock driver produces silence

The running kernel's `snd-hda-codec-cs8409` is the mainline driver. Its PCI
quirk table contains only Dell subsystem IDs:

```
SND_PCI_QUIRK(0x1028, 0x0A11, "Bullseye", CS8409_BULLSEYE)
SND_PCI_QUIRK(0x1028, 0x0A77, "Cyborg",   CS8409_CYBORG)
... (Dolphin, Warlock, Odin)
```

There is no Apple entry and no Apple code in the module. On `0x106b3900`
`snd_hda_pick_fixup()` finds nothing and `codec->fixup_id` stays
`HDA_FIXUP_ID_NOT_SET`. The driver then runs generic HDA autoconfig:

```
snd_hda_codec_cs8409 hdaudioC0D0: autoconfig for CS8409: line_outs=2
    (0x24/0x25/0x0/0x0/0x0) type:speaker
    hp_outs=1 (0x2c/0x0/0x0/0x0/0x0)
    inputs: Internal Mic=0x44, Mic=0x3c
```

Autoconfig does the "normal HDA" things correctly: it powers the converter
nodes, marks pin `0x24`/`0x25` as outputs, exposes a stereo PCM and a mixer.
That is why the card appears, `aplay` opens it, and the volume slider moves.
But autoconfig knows nothing about node `0x47` or the external amps, so:

* the speaker amplifiers are never brought out of reset or programmed;
* the CS42L83 is never initialised;
* the TDM/ASP format the amps expect is never configured.

Audio data flows into the codec and stops there. The result is a perfectly
enumerated, perfectly silent sound card.

## 3. What this driver adds

The package patches the kernel's own `cs8409.c` / `cs8409.h` rather than
shipping a separate module. That is deliberate:

* the codec driver owns the HDA device; a second driver cannot bind to the
  same codec;
* the Apple path needs the driver's internal spec, vendor-coef helpers and
  PCM plumbing;
* keeping the in-tree driver as the base means Dell/CS42L42 behaviour is
  untouched.

Two patch hunks are applied (see `src/patches/`):

### 3.1 Probe fallback (`cs8409.c`)

```c
snd_hda_pick_fixup(codec, cs8409_models, cs8409_fixup_tbl, cs8409_fixups);

if (codec->fixup_id == HDA_FIXUP_ID_NOT_SET) {
        cs8409_remove(codec);          /* undo the stock spec */
        err = cs8409_apple(codec);     /* Apple-specific probe */
        return err;
}
```

If a Dell quirk matched, the stock path runs exactly as before. Otherwise the
Apple probe takes over. This is why the driver can live in the same module as
the Dell support without a per-machine kernel build.

### 3.2 Apple spec and initialisation (`cirrus_apple.h`, included by `cs8409.c`)

`cs8409_apple()`:

1. allocates a `cs8409_apple_spec` (separate from `cs8409_spec`);
2. validates `codec->core.subsystem_id` against the known Apple IDs and
   returns `-ENODEV` for anything else;
3. applies the MacBook pin configuration and GPIO setup — the 14,3 uses
   `gpio_mask = 0x07`, other models use `0x0f`;
4. builds the PCMs with the format the hardware actually accepts
   (**44.1 kHz, S24_LE/S32_LE, 2 or 4 channels**);
5. runs `cs_8409_boot_setup()`, which for `0x106b3900` calls
   `cs_8409_real_config()`.

`cs_8409_real_config()` replays the initialisation sequence captured from
macOS: HDA verbs for the bridge plus the vendor-node `0x47` coefficient writes
that clock and program the amplifiers and the CS42L83. The tables live in
`patch_cirrus_boot84.h`, `patch_cirrus_real84.h` and
`patch_cirrus_real84_i2c.h`. They are plain C arrays — no firmware blob and
no userspace helper is required.

Pin/jack handling (headphone detect, automute) is implemented in the same
file via unsolicited responses on the CS42L83 and the HDA jack layer.

### 3.3 Fixed hardware format

The amplifier path is not a general-purpose HDA DAC. Apple drives it at a
fixed 44.1 kHz/24-bit TDM format. The driver therefore advertises
`SNDRV_PCM_RATE_44100` and `S24_LE | S32_LE` on the analog PCM. PipeWire
resamples everything else transparently, which is why normal desktop audio
works at any source rate.

The raw `hw:` device has no volume control (the amps run at a fixed gain),
so use `plughw:` or, better, the PipeWire default sink.

## 4. Boot-time call flow

```
snd_hda_intel probe
  └─ cs8409_probe()
       ├─ cs8409_alloc_spec()
       ├─ snd_hda_pick_fixup()           → NOT_SET on Apple
       ├─ cs8409_remove()                (free stock spec)
       └─ cs8409_apple()
            ├─ cs8409_apple_alloc_spec()
            ├─ SSID check (0x106b3900 / 0x106b3300 / 0x36xx / iMac IDs)
            ├─ pin config + GPIO
            ├─ cs_8409_apple_parse_auto_config()
            ├─ cs_8409_apple_build_pcms()
            └─ cs_8409_boot_setup()
                 └─ cs_8409_real_config()
                      └─ vendor-node 0x47 I2C/coef writes
                           ├─ speaker amplifiers
                           └─ CS42L83
```

`cs_8409_apple_boot_init()` is called after the PCMs are built and forces the
stream format, installs the playback/capture prepare hooks and marks the
machine as initialised.

## 5. Building on 6.17+ kernels

Linux 6.17 moved the HDA sources from `sound/pci/hda` to `sound/hda` and
renamed several files. The Apple code targets that layout. The build works
like this:

1. take the kernel's `sound/hda` directory from the installed kernel source
   (`/usr/src/linux-source-<base>.tar.bz2` on Ubuntu, a kernel source tree on
   Fedora/Arch, or an explicit `--source` tree);
2. replace four Makefiles so only `codecs/cirrus/` is built
   (`src/makefiles/`);
3. copy the Apple headers into `codecs/cirrus/`;
4. apply the two patches;
5. `make -C /lib/modules/$(uname -r)/build M=<tree> modules`.

Only `cs8409.o`, `cs8409-tables.o` and the Apple code are compiled; the rest
of the HDA subsystem is used as headers and links against the installed
kernel's exported symbols. That is why the build is fast (~20 s) and produces
a single `snd-hda-codec-cs8409.ko`.

The module is installed to `/lib/modules/<ver>/updates/...`, which `depmod`
ranks above the stock `kernel/...` copy. The stock file is not overwritten,
so `uninstall.sh` (or `dkms remove`) immediately restores the original.

## 6. Verification markers

With debug printing at its default (off), success is visible as:

```bash
aplay -l | grep CS8409
# card 0: PCH [HDA Intel PCH], device 0: CS8409 Analog [CS8409 Analog]

journalctl -k -b | grep -i cs8409
# ... Primary cs8409
# ... Primary patch_cs8409 NOT FOUND trying APPLE
# ... Post Patching for CS8409 Apple
```

The last line only appears after `cs_8409_real_config()` has run, i.e. after
the amplifiers have been programmed. `scripts/doctor.sh` checks for these
strings and for the `cs8409_apple` symbol inside the installed `.ko`.

## 7. Compatibility and validation

* Build-tested against Ubuntu 26.04, kernel `7.0.0-28-generic`, with kernel
  source `7.0.0`. The upstream patches applied with small offsets; the
  resulting module reports `vermagic: 7.0.0-28-generic`.
* The codec/amplifier sequences come from the community `snd_hda_macbookpro`
  driver, which has been used on MacBookPro13,x/14,x and iMac18,x since 2016.
* The 14,3-specific path (`0x106b3900`, `gpio_mask 0x07`, `real_config`) is
  explicit in the source; no model autodetection guesswork is involved.
* Runtime validation on this exact machine must be done after a reboot, since
  the codec is only probed once at boot. `scripts/verify.sh --tone` is the
  quickest end-to-end check.

## 8. Source map

| Path | Purpose |
|---|---|
| `src/patches/patch_cs8409.c.diff` | probe fallback + include of Apple code |
| `src/patches/patch_cs8409.h.diff` | Apple structs/fields in the codec header |
| `src/apple/cirrus_apple.h` | Apple probe, PCM setup, jack handling |
| `src/apple/patch_cirrus_boot84.h` | boot-time amplifier sequences |
| `src/apple/patch_cirrus_real84.h` | runtime path configuration |
| `src/apple/patch_cirrus_real84_i2c.h` | vendor-node I2C helpers |
| `src/apple/patch_cirrus_new84.h` | model selection / boot setup |
| `src/makefiles/` | minimal kbuild makefiles for `sound/hda` |
| `scripts/prepare-source.sh` | source acquisition, grafting, build |
| `dkms.conf` | DKMS package definition |
