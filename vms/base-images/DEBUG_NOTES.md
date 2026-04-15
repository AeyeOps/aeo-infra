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

**Update 2026-04-15**: cdboot does NOT time out in any config we've seen.
Earlier notes about a 10 s timeout were wrong — the "Shell appeared"
outcome of the prior session was produced some other way (possibly boot
option fall-through when that particular boot attempt failed for a
different reason). In a minimal config with blank NVRAM, cdboot sits on
"Press any key" indefinitely (observed 60 s+).

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

## Debug Tooling in This Directory

- **`launch-minimal-debug.sh`** — starts the minimal QEMU config that
  reliably reaches the embedded UEFI Shell. No QMP, no extra USB, no
  `bootindex`. VNC on `:2` (port 5902). Uses firmware/disk in `/tmp/winboot/`.
- **`vnc_full.py`** — full-RFB 3.8 client. Both `--type TEXT` (with shift
  handling for uppercase/symbols) and `--screenshot PATH.ppm`. Does the
  complete handshake-plus-drain sequence required for key events to
  actually reach the guest.

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
