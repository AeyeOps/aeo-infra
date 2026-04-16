# ARM64 UEFI Boot — Technical Model

How Windows 11 ARM64 boots on QEMU `virt` with TianoCore firmware, what
we've observed, and what we don't yet understand. Read this before
changing anything in the boot flow.

## How the boot chain works

```
QEMU starts
  → TianoCore (EDK2 BdsDxe) reads NVRAM boot variables
  → Tries boot entries in BootOrder sequence
  → First match on USB media: El Torito → loads efisys.bin FAT image
    → efisys.bin contains cdboot.efi
    → cdboot.efi prints "Press any key to boot from CD or DVD......"
    → If a key arrives: chain-loads bootmgfw.efi (= bootaa64.efi)
      → bootmgfw reads BCD (registry hive) for boot config
      → BCD says: load boot.wim as RAM disk via boot.sdi, device class = CD
      → WinPE starts → Windows Setup UI
    → If no key (timeout ~15 s): BdsDxe marks boot entry failed, tries next
  → If no bootable entry: drops to embedded UEFI Shell
```

### Device paths on ARM64 QEMU virt

With Windows ISO on USB + blank SCSI disk, TianoCore's `map` shows:

| Shell name | Device path | What it is |
|------------|-------------|------------|
| FS0 / BLK1 | `USB(0x1,0x0)/CDROM(0x0)` | ISO 9660 layer (empty on ARM64 ISOs) |
| FS1 / BLK2 | `USB(0x1,0x0)/VenMedia(C5BD4D42…)` | UDF layer (full tree, readable) |
| BLK0 | `USB(0x1,0x0)` | Raw USB device |
| BLK3 | `Scsi(0x0,0x0)` | Build disk |

### BCD device-class constraint

The ISO's BCD (at `efi/microsoft/boot/BCD`) is a registry hive configured
for **CD ramdisk boot**. Key elements:

- `11000001` (app device) → `[boot]` (resolves to CD device class)
- `21000001` (OS device) → `[boot]`
- `31000003` (ramdisk source) → `\sources\boot.wim`
- `32000004` (sdi path) → `\boot\boot.sdi`

When bootmgfw runs from a non-CD context (FAT32 ESP, UEFI Shell `FS1:\`,
`bcfg`-registered entry with VenMedia path), `[boot]` doesn't resolve to
any device. Result: bootmgfw either silently exits or hangs indefinitely.
This is why all "extract bootmgfw + BCD to ESP" approaches fail.

## Facts established

These are verified observations with raw data. Each stands on its own.

### NVRAM wipe

`truncate -s 64M build.vars` on an already-64 MiB file does nothing.
Contents are preserved. Stale NVRAM carries failed boot state that makes
TianoCore's retry behavior diverge from the clean case.

```bash
# correct wipe — always use this
rm -f build.vars && truncate -s 64M build.vars
```

Two days of debugging (April 2026) were caused by this single mistake.

### ISO filesystem layout

Windows ARM64 ISOs use UDF as the primary filesystem with an ISO 9660
bridge that's effectively empty. FS0 (ISO 9660) has no useful files at
root. FS1 (UDF) has the full directory tree (`efi/`, `boot/`, `sources/`).
The Shell can `ls`, `cd`, `type`, and execute `.efi` files from FS1.

### VNC RFB 3.8 handshake

A minimal RFB client (connect → ServerInit → KeyEvent) gets keys accepted
by QEMU's VNC server but they don't reliably reach the guest. The full
sequence is required:

```
Version → Security → ClientInit → ServerInit →
SetPixelFormat → SetEncodings → FramebufferUpdateRequest →
drain first framebuffer update → THEN send KeyEvent messages
```

Implementation: `vnc_full.py` in this directory.

### Input delivery to cdboot vs. Shell

VNC KeyEvents with full RFB handshake reach the UEFI Shell deterministically.
The same keys reach cdboot.efi only ~50% of the time. HMP `sendkey` doesn't
work at all (no PS/2 on ARM64 virt). QMP `input-send-event` works ~25% of
the time.

### ARM64 virt ignores boot hints

`-boot strict=on` and `bootindex=N` on USB devices are ignored by TianoCore
on ARM64 `virt`. Firmware auto-boots removable USB media regardless. The only
way to prevent cdboot from running first is to not attach the ISO.

## What we don't understand

These are open questions. Solving any of them may unlock a deterministic
boot path. Do not declare these answered without source-level evidence.

### 1. Why does cdboot's input poll race?

cdboot uses `gBS->WaitForEvent` or `EFI_SIMPLE_TEXT_INPUT_PROTOCOL.ReadKeyStroke`
to detect a keypress. VNC keys reach the UEFI Shell through the same protocol
deterministically. Why does cdboot see only ~50% of keystrokes?

Hypotheses (untested):
- cdboot may poll with a short timeout and only check once per dot-print cycle
- QEMU's xHCI USB driver may delay input dispatch during the El Torito
  boot-from-media phase differently than during Shell execution
- cdboot may use a different ConIn handle than the Shell does

**To investigate**: read the EDK2 BdsDxe source (`MdeModulePkg/Universal/BdsDxe`)
and the SimpleTextInput implementation for USB HID in TianoCore. Disassemble
or `strings` the Windows `cdboot.efi` binary from the ISO's efisys.bin to see
what EFI protocol calls it makes.

### 2. What exactly does BCD need to resolve from a non-CD path?

We know `[boot]` in BCD means "the device I was loaded from" and it expects
CD device class. We haven't read the actual BCD specification or tried to
rewrite the device elements with `hivex`.

**To investigate**: read Microsoft's BCD reference
(learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcd-system-store-settings-for-uefi).
Dump the ISO's BCD with `hivexsh` and identify exactly which elements need
changing for hard-disk boot. The hivex rewrite has never been attempted.

### 3. Is the race in QEMU, TianoCore, or cdboot?

USB HID input on ARM64 QEMU flows: host keyboard event → QEMU VNC/QMP →
QEMU xHCI emulation → TianoCore USB driver → SimpleTextInput → cdboot
ReadKeyStroke. The flakiness could be at any layer.

**To investigate**: QEMU's `-trace` option can log xHCI events. TianoCore
debug builds emit ConIn dispatch logs. Either would narrow the location.

### 4. Does `cdboot_noprompt.efi` actually exist for ARM64?

The ISO contains `efisys_noprompt.bin` alongside `efisys.bin`. Prior
attempts to use it crashed on ARM64 (approach #3 below). We don't know
whether the crash was due to the binary being x86-only, a bad binary
swap, or something else.

**To investigate**: `file` or `objdump` on both `cdboot.efi` (from
efisys.bin) and the equivalent from `efisys_noprompt.bin`. Check
architecture headers.

## Upstream references

Consult these before experimenting:

- **EDK2 source** (TianoCore): https://github.com/tianocore/edk2
  - BdsDxe boot logic: `MdeModulePkg/Universal/BdsDxe/`
  - SimpleTextInput: `MdeModulePkg/Universal/Console/ConSplitterDxe/`
  - USB HID: `MdeModulePkg/Bus/Usb/UsbKbDxe/`
- **BCD reference**: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcd-system-store-settings-for-uefi
- **WinPE boot**: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-intro
- **QEMU ARM virt**: https://www.qemu.org/docs/master/system/arm/virt.html
- **ARM64 UEFI spec**: https://uefi.org/specifications (UEFI 2.10, Chapter 7 — Boot Services)
- **hivex** (BCD editing): `apt install libhivex-bin` — `hivexsh`, `hivexget`, `hivexregedit`

## Experiment log

Raw data from 18 experiments across April 13–15 2026. Recorded as
observations, not verdicts. Some may be worth revisiting with better
understanding.

| # | What was tried | What happened | What it might mean |
|---|---------------|---------------|-------------------|
| 1 | Rebuild ISO with `cdboot_noprompt.efi` via genisoimage | El Torito extent only covers 1.7 MB efisys, not full disc | genisoimage can't produce a valid El Torito for large ISOs |
| 2 | Rebuild ISO with xorriso `-append_partition` | TianoCore classified GPT-format ISO as "USB HARDDRIVE" | xorriso GPT wrapper changes how firmware sees the device |
| 3 | Binary-patch `efisys.bin` → `efisys_noprompt.bin` in ISO | Crash on ARM64 at "Start boot option" | `cdboot_noprompt.efi` may be x86-only or the swap was wrong |
| 4 | HMP `sendkey` | No effect | No PS/2 controller on ARM64 virt — expected |
| 5 | Minimal RFB client (no full handshake) | Keys accepted, not routed to guest | Full handshake required — see facts above |
| 6 | QMP `input-send-event` key spam | ~25% hit rate | Same input race as VNC but via different path |
| 7 | UEFI Shell `startup.nsh` → `FSx:\efi\boot\bootaa64.efi` | bootmgfw runs, silently exits | BCD device-class mismatch — see facts above |
| 8 | Hot-plug ISO via HMP `drive_add` | Shell can't browse hot-plugged device | TianoCore may not re-enumerate media after boot |
| 9 | ISOs as SCSI CD-ROM | Shell maps but can't browse | ARM64 SCSI CDROM driver limitation? Untested further |
| 10 | bootmgfw + BCD + boot.wim + boot.sdi on FAT32 ESP | bootmgfw hangs (auto-boot) or exits (Shell) | BCD `[boot]` doesn't resolve on non-CD media |
| 11 | Autounattend.xml on ESP partition | WinPE didn't see it | WinPE doesn't assign drive letters to ESP (type EF00) |
| 12 | Autounattend.xml on third USB FAT image | QMP key timing broke | USB enumeration timing changes with 3 devices |
| 13 | Combined VirtIO + Autounattend ISO | QMP timing broke | Larger ISO changed USB enumeration |
| 14 | Full-RFB VNC keyspam against cdboot (71 presses / 21 s) | No effect on cdboot prompt | See "input delivery" in facts — mechanism unknown |
| 15 | `FS1:\efi\boot\bootaa64.efi` from Shell | bootmgfw silently exits | VenMedia device path ≠ CDROM — BCD mismatch |
| 16 | ESP on SCSI with ISO BCD, no ISO attached | bootmgfw exits or hangs | Same BCD mismatch as #10 |
| 17 | ISO + ESP + fresh NVRAM, cold-boot reproduction | 1/3 reached Setup | Non-reproducible; mechanism of the 1 success unknown |
| 18 | Boot Manager menu + VNC Space spam (8 Hz, 22 s) | ~50% per attempt (6/14) | Input race with cdboot — see open questions above |

## Paths not yet tried

### Hivex BCD rewrite (highest priority)

Rewrite the ISO's BCD from CD-ramdisk to hard-disk boot semantics using
`hivexsh`. Place rewritten BCD + bootmgfw + boot.wim + boot.sdi on a
FAT32 ESP. No cdboot involvement, no input race, deterministic.

Never attempted. See "What we don't understand" §2.

### wimboot

Minimal bootloader that reads WIM files directly — no BCD, no ramdisk
semantics. Simpler than bootmgfw. Never tested on ARM64.

### Prebuilt VHDX

Microsoft ships ARM64 Windows as VHDX (Windows Insider, Windows Dev Kit).
Convert to raw, customize offline with libguestfs + hivex. Removes the
entire boot problem. Trade-off: bound to Microsoft's shipped image.
