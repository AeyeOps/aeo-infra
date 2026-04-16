# Windows 11 ARM64 Unattended Build — Debug Notes

Findings from extensive debug sessions on automated Windows 11 ARM64 install via
QEMU on an ARM64 host. Saved here so insights travel with the repo.

## The Problem

`./winvm.sh image build` needs to boot Windows Setup from the Windows 11 ARM64
ISO, extract the image to a disk, and run through OOBE + FirstLogonCommands
(OpenSSH, static IP, Tailscale) fully unattended — producing a reusable base
image for fast copy-on-write overlays.

## Hard Blockers (Verified)

### 1. cdboot.efi on ARM64 does not accept programmatic input

The `Press any key to boot from CD or DVD` prompt from Windows ARM64's
`cdboot.efi` cannot be dismissed by any of:

- **HMP `sendkey`** — sends PS/2 scancodes. ARM64 `virt` has no PS/2 controller,
  only USB keyboard. Keys never reach the guest.
- **QMP `input-send-event`** — works ~2/8 attempts with identical config.
  Unreliable, probably a timing race with USB enumeration.
- **VNC KeyEvent with full RFB 3.8 handshake** — verified on 2026-04-15:
  71 space presses over 21 s through a fully-primed RFB connection had no
  effect on cdboot's prompt. Full-RFB input reaches the *Shell* fine but
  does NOT reach cdboot.

**Update 2026-04-15 (second revision)**: cdboot.efi DOES time out, after
~15–20 s of "Press any key to boot from CD or DVD......" (dots advance
visibly as the countdown progresses). TianoCore then logs:

```
BdsDxe: failed to start Boot0001 "UEFI QEMU QEMU USB HARDDRIVE …" … : Time out
```

and moves to the next boot entry.

Earlier sessions observed cdboot "hanging indefinitely" because the
host's `build.vars` NVRAM file was never *actually* wiped between runs.
`truncate -s 64M build.vars` on an already-64 MiB file is a no-op — it
leaves NVRAM contents intact. To actually reset NVRAM you must `rm
build.vars` first, then `truncate -s 64M` (zero-fills). With a stale
NVRAM carrying a mix of successful/failed boot state, TianoCore's boot
order and retry behavior diverges from the clean case and cdboot can
appear to hang.

**How to wipe NVRAM correctly:**
```bash
rm -f build.vars && truncate -s 64M build.vars
```

### 2. TianoCore ARM64 UEFI Shell CAN read UDF (FS1), not ISO 9660 (FS0)

**Previous note was wrong.** On 2026-04-15 we confirmed the Shell reads
files from the Windows ISO's UDF layer just fine:

```
FS0 (ISO 9660, device path ends CDROM(0x0))     — effectively empty on
                                                   Windows 11 ARM64 ISOs
                                                   (ISO 9660 is only a
                                                   bridge; UDF is primary)
FS1 (UDF,      device path ends VenMedia(GUID)) — full tree, readable
```

`ls FS1:\`, `cd FS1:\efi\boot`, and `type FS1:\...` all work. The prior
session's "Shell can't read CDROM" finding was based on FS0 tests where
the filesystem was actually empty.

**However**: invoking `FS1:\efi\boot\bootaa64.efi` from the Shell *does*
launch Windows Boot Manager (bootmgfw) — screen clears, binary runs — but
it **silently exits back to the Shell prompt** without transferring to
WinPE. Same result whether run with root as current device or with FS1 as
current device. See §4 for the likely cause.

### 3. Full RFB 3.8 handshake is required for VNC key injection to reach the guest

A minimal RFB client (connect, ServerInit, send KeyEvent) gets keys
*accepted* by QEMU's VNC server but they don't reach the guest reliably.

A full client must do:

```
1. Version handshake (12 bytes)
2. Security handshake (None = type 1)
3. ClientInit (shared = 1)
4. Read ServerInit (width, height, pixel format, name)
5. SetPixelFormat (msg 0)
6. SetEncodings (msg 2, encoding 0 = Raw)
7. FramebufferUpdateRequest (msg 3)
8. Drain the first framebuffer update from the server
9. THEN send KeyEvent (msg 4) messages
```

Reference implementation that works: see `vnc_full.py` below.

### 4. bootmgfw (bootaa64.efi) silently exits when launched outside a CD context

Two variants observed:

**From a hard disk ESP** — firmware loads bootmgfw successfully, then it
"hangs at Start boot option" (original finding).

**From the Shell at `FS1:\efi\boot\bootaa64.efi`** (UDF layer) — bootmgfw
clears the screen, runs briefly, and returns to the Shell prompt with no
visible error (2026-04-15 finding). Likely cause: the device path of
FS1 ends in `VenMedia(GUID)` (synthetic UDF volume), not `CDROM(0x0)`,
so the CD-ramdisk device class the ISO's BCD expects doesn't resolve.

Either path points to the same root cause: the BCD on the ISO is
configured for CD ramdisk boot. BCD modification with `hivex` (unexplored
path C) is the way forward.

We tried extracting `efi/boot/bootaa64.efi` (which IS bootmgfw.efi, verified
via `strings`) + `efi/microsoft/boot/BCD` + `boot/boot.sdi` + `sources/boot.wim`
from the ISO onto a 1 GB FAT32 ESP on the build disk.

UEFI firmware loads bootmgfw successfully. It never transfers to WinPE.

Root cause: the BCD on the Windows ISO is configured for **CD ramdisk boot**.
It references `[boot]` device paths and creates a WinPE RAM disk from
`boot.wim` using `boot.sdi`. These semantics don't work from a hard disk ESP.

To make direct-ESP-boot work, the BCD would need rewriting to use hard-disk
boot semantics — doable with `hivex` on Linux (BCD is a registry hive), but
not yet attempted.

### 5. `-boot strict=on` is ignored on ARM64 `virt`

TianoCore on ARM64 auto-boots removable USB media regardless of the QEMU
`bootindex` hint or `-boot strict=on`. The only reliable way to prevent
cdboot from running first is to not attach the ISO until after the desired
boot target has run.

## Attempted Approaches (All Unsuccessful)

| # | Approach | Why it failed |
|---|----------|---------------|
| 1 | Rebuild ISO with `cdboot_noprompt.efi` via genisoimage | El Torito extent too small (covers only 1.7 MB efisys, not full disc) |
| 2 | Rebuild ISO with xorriso `-append_partition` | GPT-format ISO was misclassified as "USB HARDDRIVE" by TianoCore |
| 3 | Binary-patch `efisys.bin` → `efisys_noprompt.bin` in original ISO | `cdboot_noprompt.efi` crashes on ARM64 at "Start boot option" |
| 4 | HMP `sendkey` to dismiss "Press any key" | No PS/2 on ARM64 virt |
| 5 | Minimal RFB client for VNC key injection | Keys accepted but not routed to guest (need full handshake) |
| 6 | QMP `input-send-event` with key spam | Works inconsistently, unreliable timing |
| 7 | Seeded ESP with UEFI Shell + startup.nsh trying all FSx paths | Shell can't execute from USB CDROM filesystems |
| 8 | Hot-plug ISO via HMP `drive_add` after Shell boots | Shell still can't browse/execute from hot-plugged device |
| 9 | ISOs as SCSI CD-ROM instead of USB | Shell can map them but can't browse |
| 10 | Extract bootmgfw + BCD + boot.wim + boot.sdi to ESP | bootmgfw hangs at "Start boot option" — BCD is for CD boot |
| 11 | Autounattend.xml on disk ESP | WinPE doesn't see ESP partitions (no drive letter) |
| 12 | Autounattend.xml on third USB FAT image | Third USB device breaks QMP reliability |
| 13 | Combined VirtIO + Autounattend ISO via genisoimage | Larger ISO (1.4 GB) changed USB enumeration timing, broke QMP |
| 14 | Full-RFB VNC key-spam against cdboot (71 presses / 21 s) | cdboot ignores VNC input even with correct handshake |
| 15 | `FS1:\efi\boot\bootaa64.efi` from Shell (FS1 as current device) | bootmgfw silently exits — BCD CD-ramdisk semantics don't match FS1's VenMedia device path |
| 16 | Fresh GPT+FAT32 ESP on SCSI disk with unmodified ISO BCD + bootaa64.efi + boot.wim + boot.sdi, no ISO attached | Firmware auto-boots the ESP, bootmgfw exits silently → falls through to Shell (same as #10). Manually re-invoking from Shell produces a hang (60 s+ with no screen update) rather than silent exit — bootmgfw appears to spin waiting on a device reference in BCD that doesn't resolve on this non-CD media. |
| 17 | ISO on USB + ESP disk on SCSI + fresh NVRAM, repeated cold-boot reproduction of the "one-time Setup success" | 1/3 cold boots reached Setup (r1). r2, r3 hung at "BdsDxe: starting Boot0002 HARDDISK" — ESP bootmgfw spun forever. Confirms one-time success was non-reproducible. |
| 18 | ISO-only + blank SCSI + fresh NVRAM, drive through Boot Manager menu with full-RFB persistent Space-key spam against cdboot prompt | Reaches the Shell deterministically at t≈12 s. From Shell: `exit` → menu → Down Down Enter → Boot Manager → Enter on USB HARDDRIVE → 22 s of Space spam. ~40–50% single-attempt hit rate. 3–5× retry wrapper succeeds in practice. See "Task #9 Outcome" below. |

## Promising Unexplored Paths

### A. UEFI Shell `bcfg boot add` to register new boot option

Use full-RFB VNC typing to issue:
```
bcfg boot add 0 BLK1:\efi\boot\bootaa64.efi "Windows Setup"
reset
```

If TianoCore stores the new boot option in NVRAM vars, the next boot should
try it. Since BLK1 is the raw ISO block device and bcfg may use block-level
device paths, this might bypass the file-reading limitation.

### B. Copy bootaa64.efi via block-device reads into a hard disk FAT partition

Use `dh -b` to find handles, `load` to trigger driver binding, or raw block
reads via a helper EFI app. Extract bootaa64.efi (2.7 MB) into a FAT
partition that the Shell can execute from.

### C. Modify the BCD with hivex for hard-disk boot

BCD is a Windows registry hive. `hivex` (Debian package `libhivex-bin`)
can read and modify hives on Linux. Rewrite the boot device paths from
`[boot]` ramdisk to explicit hard-disk semantics, then the "bootmgfw + BCD
+ boot.wim on ESP" approach would work.

### D. Use wimboot instead of bootmgfw

wimboot is a minimal bootloader that reads WIM files directly — no BCD,
no ramdisk semantics. Much simpler than bootmgfw.

### E. Skip installation entirely — start from a prebuilt Windows ARM64 VHDX

Microsoft publishes ARM64 Windows evaluation images as VHDX (Windows
Insider Program, Windows Dev Kit). These are already installed and
generalized — no "Windows Setup" phase required, so the entire
cdboot/bootmgfw/BCD rabbit hole becomes irrelevant.

Workflow:

1. Download the official ARM64 VHDX from the Windows Insider ARM64 page.
2. `qemu-img convert -f vhdx -O raw <in>.vhdx base.img` (or attach VHDX
   directly — QEMU supports it).
3. Inject customizations offline via `libguestfs` + `hivex`:
   - Enable OpenSSH Server via `Setup-Service` and registry keys.
   - Drop a FirstLogonCommands / RunOnce script that installs Tailscale
     and sets a static IP.
   - Optionally place a small `unattend.xml` at
     `C:\Windows\Panther\unattend.xml` or `C:\Windows\System32\Sysprep\`.
4. Boot the modified image — customizations run on first login.

This removes the need to drive Windows Setup at all. The same
`winvm.sh image build` target just becomes "fetch VHDX, inject
customizations, mark as ready" — fully offline, no QEMU input
injection, no UEFI Shell gymnastics.

Trade-off: you're bound to the image Microsoft ships (version, edition,
preinstalled bloat). For a dev/test base image this is usually a good
trade; for reproducible production images, it isn't.

## Key Discovery: the "right" minimal path

The cleanest unblocked path discovered this session:

1. **Minimal QEMU config** — Windows ISO on USB, blank raw disk, usb-kbd,
   NO bootindex, NO QMP, NO extra USB devices.
2. cdboot runs, times out after ~10s, firmware falls through to embedded
   UEFI Shell.
3. Shell auto-executes `startup.nsh` from any filesystem if found.
4. **Full-RFB VNC automation** can then drive the Shell interactively —
   type commands, observe output via screen dumps.

This path avoids the cdboot-input-injection problem entirely. The remaining
work is finding a Shell command sequence that successfully launches Windows
Setup despite the CD-ROM filesystem access limitation.

## Task #9 Outcome — Boot Manager + Keyspam Path (2026-04-15 late)

**Verdict**: Windows Setup is reachable via a repeatable but flaky sequence
through the UEFI Boot Manager Menu. Single-attempt success rate is ~40–50%
across 14 trials. A 3–5× retry wrapper achieves reliable eventual success.

### Winning sequence

```
1. Launch QEMU (ISO on USB, blank build disk on SCSI, usb-kbd, NO bootindex,
   NO QMP, NO extra USB devices) with fresh NVRAM:
      rm -f build.vars && truncate -s 64M build.vars
2. Wait ~12 s — cdboot times out on Boot0001 (USB HARDDRIVE), firmware
   falls through build disk (blank) → embedded UEFI Shell.
3. From Shell prompt, type "exit\n" → TianoCore front-page menu appears.
4. Arrow: Down Down Enter → Boot Manager Menu (USB HARDDRIVE pre-highlighted).
5. Press Enter → cdboot.efi starts, prints "Press any key to boot from CD
   or DVD......" with ~15 s countdown.
6. Immediately spam Space keys via a single persistent RFB connection
   (~22 s at 8/s, 60 ms key-hold). When cdboot's SimpleTextInput catches
   a press it chain-loads bootmgfw which loads boot.wim which launches
   Windows Setup language-selection UI.
7. If the screenshot at step 6 + 10 s shows "Press any key..." with only
   2–3 dots (cdboot-prompt frozen) or the Boot Manager Menu (cdboot timed
   out and returned), kill QEMU and retry from step 1 up to N times.
```

### Per-attempt failure modes (observed)

- **"cdboot times out"** — 75 space keys never landed on SimpleTextInput;
  cdboot prints its full "......" (6 dots) then BdsDxe marks Boot0001
  failed and returns to Boot Manager.
- **"cdboot dismissed but bootmgfw hangs"** — one space key landed, cdboot
  chain-loads bootmgfw, but framebuffer is frozen at the cdboot prompt
  with 2–3 dots, no further progress. bootmgfw appears to be blocked on
  something internally (possibly the same CD-ramdisk BCD-device race as
  the hang from §4, but before the ESP fall-through since there is no ESP
  in this config).
- **"success"** — cdboot key-press caught, bootmgfw loads in <5 s, boot.wim
  → WinPE → Setup language UI renders at ~t=30 s after qemu start.

### Tools for this approach

- `drive-setup.sh` — single-attempt driver (steps 1–6 above).
- `drive-setup-retry.sh` — retry wrapper, default `MAX_ATTEMPTS=5`.
  Detects success by mean-gray heuristic on `s4-setup.png` (Setup UI's
  yellow background lifts mean intensity well above text-mode screens).
- `vnc_spam_keys.py` — single-connection key spammer (rate, duration,
  hold-ms configurable). Required because re-handshaking in a loop
  races with cdboot's USB xHCI state.
- `vnc_send_keys.py` — named-key sender for navigation (Down, Enter, Esc).

### Unresolved: single-attempt determinism

The keyspam arrives at QEMU's VNC server reliably (traced via per-key
stderr in `vnc_spam_keys.py`), but cdboot's SimpleTextInput polling
against the firmware xHCI driver has a ~50% hit rate. Attempts to
improve:

| Variant | Hold-ms | Rate | Pre-delay | Outcome |
|---------|---------|------|-----------|---------|
| 22 s, 8/s, 60 ms hold | 60 | 8/s | 0 s | ~50% success (4/8) |
| 25 s, 4/s, 350 ms hold | 350 | 4/s | 0 s | Failed (1/1 tested) |
| 15 s, 5/s, 200 ms hold, 4 s pre-delay | 200 | 5/s | 4 s | Failed (1/1) |

No tuning knob reached >70% single-attempt reliability in this session.
Root cause is likely a race between firmware USB-driver polling and
cdboot's SimpleTextInput ReadKeyStroke — not something tunable from the
host side.

### Next steps that were NOT tried in Task #9

1. **Use QMP `input-send-event` alongside VNC keyspam.** Prior sessions
   flagged QMP as 2/8 reliable alone; combining both input channels might
   push the hit rate higher.
2. **Extract a minimal `cdboot_noprompt.efi`** and hot-swap it inside the
   El Torito image without xorriso GPT format issues (approach #3 in the
   table). Requires building a custom efisys.bin and rewriting ISO in
   place, which has known pitfalls.
3. **Offline modify the ISO's BCD via hivex to flip `custom:46000001`**
   from CD-ramdisk class to hard-disk class, then use the direct-ESP-boot
   path (approach #10) deterministically. This is the "Promising
   Unexplored Path C" from above.

## Debug Tooling in This Directory

- **`launch-minimal-debug.sh`** — starts the minimal QEMU config that
  reliably reaches the embedded UEFI Shell. No QMP, no extra USB, no
  `bootindex`. VNC on `:2` (port 5902). Uses firmware/disk in `/tmp/winboot/`.
- **`vnc_full.py`** — full-RFB 3.8 client. Both `--type TEXT` (with shift
  handling for uppercase/symbols) and `--screenshot PATH.ppm`. Does the
  complete handshake-plus-drain sequence required for key events to
  actually reach the guest.
- **`vnc_send_keys.py`** — named-key sender (Down, Up, Enter, Esc, F-keys).
  Does its own handshake per invocation; good for one-shot navigation,
  not for sustained spam.
- **`vnc_spam_keys.py`** — single-connection persistent spammer. Hold one
  RFB session open and send a key repeatedly at a configurable rate for
  a configurable duration. Required for racing cdboot's "any key" prompt.
- **`drive-setup.sh`** — end-to-end single-attempt driver: wipes NVRAM,
  launches QEMU, navigates Shell→menu→BootMgr, spams space, screenshots
  final state. ~40–50% single-attempt hit rate.
- **`drive-setup-retry.sh`** — wraps `drive-setup.sh` with success
  detection and retries up to N (default 5) attempts.

Typical debug loop:
```bash
./launch-minimal-debug.sh            # background-able; VNC on 5902
sleep 15                             # let cdboot time out → UEFI Shell
./vnc_full.py --port 5902 --screenshot /tmp/s0.ppm
./vnc_full.py --port 5902 --type 'bcfg boot dump -v\n'
sleep 1
./vnc_full.py --port 5902 --screenshot /tmp/s1.ppm
```

## Mapping Table Seen in Minimal Config (2026-04-15)

With Windows ISO on USB + blank SCSI disk, the Shell's `map` yields:

| Entry | Alias | Device path | Notes |
|-------|-------|-------------|-------|
| FS0 | `CD0b0a` / BLK1 | `USB(0x1,0x0)/CDROM(0x0)` | ISO 9660 layer |
| FS1 | `HD0b0` / BLK2 | `USB(0x1,0x0)/VenMedia(C5BD4D42…)` | UDF layer |
| BLK0 | — | `USB(0x1,0x0)` | Raw USB device |
| BLK3 | — | `Scsi(0x0,0x0)` | Blank build disk |

## Related Files

- `vms/winvm.sh` — main build script (`cmd_image_build` ~line 261)
- `vms/lib/windows.sh` — `seed_build_disk`, base image helpers
- `vms/base-images/autounattend.xml` — unattended answer file
- `vms/base-images/launch-minimal-debug.sh` — minimal QEMU for Shell experiments
- `vms/base-images/vnc_full.py` — full-RFB client (typing + screenshots)
- `/usr/share/efi-shell-aa64/shellaa64.efi` — UEFI Shell binary (`apt install efi-shell-aa64`)
