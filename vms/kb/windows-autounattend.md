# Windows Autounattend.xml Reference

Model-optimized knowledge base for generating and troubleshooting Windows unattended installations,
specifically targeting ARM64 UEFI on QEMU/KVM.

Verified: 2026-04-14
Sources: Microsoft Learn, virtio-win project, Arm Learning Paths, community testing

---

## Architecture String

The `processorArchitecture` attribute in every `<component>` element MUST match the target CPU:

| Target | Value | Notes |
|--------|-------|-------|
| x86 32-bit | `x86` | Rare in modern deployments |
| x86_64 / AMD64 | `amd64` | Standard desktops/servers |
| ARM 64-bit | `arm64` | Windows on Arm, QEMU aarch64 |

For universal answer files that work on any architecture, include parallel `<component>` blocks
for each architecture in every `<settings pass>`. Windows Setup ignores components whose
`processorArchitecture` doesn't match the running system.

```xml
<!-- Example: same component duplicated for amd64 and arm64 -->
<component name="Microsoft-Windows-Setup" processorArchitecture="amd64" ...>
  <!-- config here -->
</component>
<component name="Microsoft-Windows-Setup" processorArchitecture="arm64" ...>
  <!-- identical config here -->
</component>
```

Common mistake: using `amd64` on ARM64 systems. This causes the component to be silently ignored.

---

## Configuration Passes (Execution Order)

Windows Setup processes passes in this fixed order during a clean install:

| Order | Pass | Runs When | Key Components |
|-------|------|-----------|----------------|
| 1 | `windowsPE` | Inside WinPE before OS image applied | Disk partitioning, image selection, locale, licensing, driver injection |
| 2 | `offlineServicing` | After image applied to disk, before first boot | Package/driver/update injection into offline image |
| 3 | `specialize` | First boot of installed OS | Computer name, time zone, network, domain join, RunSynchronous |
| 4 | `generalize` | Only on `sysprep /generalize` | Strip SIDs, hardware-specific settings |
| 5 | `auditSystem` | Only in audit mode | Additional drivers, system-context config |
| 6 | `auditUser` | Only in audit mode | User-context config, shell customization |
| 7 | `oobeSystem` | During Windows Welcome / OOBE | OOBE behavior, user accounts, auto-logon, FirstLogonCommands |

For unattended clean install, only passes 1, 2, 3, 7 execute (windowsPE, offlineServicing, specialize, oobeSystem).

Critical rule: settings placed in the wrong pass are silently ignored. Disk config in oobeSystem = ignored.
User accounts in windowsPE = ignored.

---

## Answer File Discovery

Windows Setup searches for answer files in this precedence order:

| Priority | Location | Required Filename |
|----------|----------|-------------------|
| 1 | Registry `HKLM\System\Setup\UnattendFile` | Any name |
| 2 | `%WINDIR%\Panther\Unattend\` | Unattend.xml or Autounattend.xml |
| 3 | `%WINDIR%\Panther\` (cached) | Cached copy, do not manually edit |
| 4 | Removable read/write media, root, by drive letter | **Autounattend.xml** |
| 5 | Removable read-only media, root, by drive letter | **Autounattend.xml** |
| 6 | `\Sources\` dir (windowsPE/offlineServicing) or `%WINDIR%\System32\Sysprep\` (other passes) | Autounattend.xml or Unattend.xml |
| 7 | `%SYSTEMDRIVE%\` root | Unattend.xml or Autounattend.xml |
| 8 | Root of drive running setup.exe | Unattend.xml or Autounattend.xml |

For QEMU unattended install: attach a small ISO as USB storage with `Autounattend.xml` at the root.
This hits priority 5 (removable read-only media). The file MUST be named exactly `Autounattend.xml`
(case-insensitive on Windows, but use this exact casing for clarity).

---

## Disk Partitioning (UEFI/GPT)

Standard UEFI partition layout for Windows 11:

```xml
<DiskConfiguration>
  <Disk wcm:action="add">
    <DiskID>0</DiskID>
    <WillWipeDisk>true</WillWipeDisk>
    <CreatePartitions>
      <CreatePartition wcm:action="add">
        <Order>1</Order>
        <Size>100</Size>
        <Type>EFI</Type>
      </CreatePartition>
      <CreatePartition wcm:action="add">
        <Order>2</Order>
        <Size>16</Size>
        <Type>MSR</Type>
      </CreatePartition>
      <CreatePartition wcm:action="add">
        <Order>3</Order>
        <Extend>true</Extend>
        <Type>Primary</Type>
      </CreatePartition>
    </CreatePartitions>
    <ModifyPartitions>
      <ModifyPartition wcm:action="add">
        <Order>1</Order>
        <PartitionID>1</PartitionID>
        <Format>FAT32</Format>
        <Label>System</Label>
      </ModifyPartition>
      <ModifyPartition wcm:action="add">
        <Order>2</Order>
        <PartitionID>2</PartitionID>
      </ModifyPartition>
      <ModifyPartition wcm:action="add">
        <Order>3</Order>
        <PartitionID>3</PartitionID>
        <Format>NTFS</Format>
        <Label>Windows</Label>
        <Letter>C</Letter>
      </ModifyPartition>
    </ModifyPartitions>
  </Disk>
  <WillShowUI>OnError</WillShowUI>
</DiskConfiguration>
```

Partition 1 (EFI): 100MB minimum, FAT32. UEFI boot partition.
Partition 2 (MSR): 16MB. Microsoft Reserved, no format.
Partition 3 (Primary): Remaining space, NTFS. Windows install target.

`<InstallTo>` must reference DiskID=0, PartitionID=3 (the NTFS partition).

Optional: Add a WinRE partition (500MB, NTFS, TypeID=DE94BBA4-06D1-4D40-A16A-BFD50179D6AC)
as partition 1, shifting others up. Not required for VMs.

---

## VirtIO Driver Injection (ARM64)

Windows 11 ARM64 does NOT include inbox virtio-scsi or virtio-blk drivers.
The virtio-win ISO must be attached during install for disk visibility.

### Driver Paths on virtio-win ISO

| Driver | Path | Purpose |
|--------|------|---------|
| viostor | `viostor\w11\ARM64\` | VirtIO block storage (virtio-blk) |
| vioscsi | `vioscsi\w11\ARM64\` | VirtIO SCSI storage (virtio-scsi-pci) |
| NetKVM | `NetKVM\w11\ARM64\` | VirtIO network |
| Balloon | `Balloon\w11\ARM64\` | Memory ballooning |
| qxldod | N/A for ARM64 | Display (x86/amd64 only) |

### Autounattend Driver Injection

Use `<DriverPaths>` in the windowsPE pass to auto-load drivers:

```xml
<component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="arm64"
           publicKeyToken="31bf3856ad364e35" language="neutral"
           versionScope="nonSxS">
  <DriverPaths>
    <PathAndCredentials wcm:action="add" wcm:keyValue="1">
      <Path>E:\vioscsi\w11\ARM64</Path>
    </PathAndCredentials>
    <PathAndCredentials wcm:action="add" wcm:keyValue="2">
      <Path>E:\NetKVM\w11\ARM64</Path>
    </PathAndCredentials>
  </DriverPaths>
</component>
```

The drive letter for the virtio-win ISO depends on USB enumeration order in WinPE and is
not guaranteed. With multiple USB devices, it could be D:, E:, or F:. Best practice:
include driver paths for all three letters. Invalid paths are silently ignored.

Alternative: use `<PathAndCredentials>` with just `E:\` to scan the entire ISO recursively.
This is slower but guaranteed to find all drivers.

### QEMU Attachment

```bash
# Windows ISO as first USB device
-drive "file=win11arm64.iso,id=cdrom0,format=raw,cache=unsafe,readonly=on,media=cdrom,if=none"
-device "usb-storage,drive=cdrom0,bootindex=0,removable=on"

# VirtIO drivers as second USB device
-drive "file=virtio-win.iso,id=virtio0,format=raw,cache=unsafe,readonly=on,media=cdrom,if=none"
-device "usb-storage,drive=virtio0,removable=on"

# Autounattend ISO as third USB device
-drive "file=autounattend.iso,id=answer,format=raw,cache=unsafe,readonly=on,media=cdrom,if=none"
-device "usb-storage,drive=answer,removable=on"
```

---

## OOBE Configuration

### Skip All Interactive Prompts

```xml
<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64"
           publicKeyToken="31bf3856ad364e35" language="neutral"
           versionScope="nonSxS">
  <OOBE>
    <HideEULAPage>true</HideEULAPage>
    <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
    <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
    <HideLocalAccountScreen>true</HideLocalAccountScreen>
    <ProtectYourPC>3</ProtectYourPC>
  </OOBE>
</component>
```

`ProtectYourPC` values:
- 1 = Recommended settings (sends data to Microsoft)
- 2 = Install updates only
- 3 = Skip entirely (no automatic updates initially)

### Local Account Creation

```xml
<UserAccounts>
  <LocalAccounts>
    <LocalAccount wcm:action="add">
      <Name>testuser</Name>
      <DisplayName>Test User</DisplayName>
      <Group>Administrators</Group>
      <Password>
        <Value>TestPass123!</Value>
        <PlainText>true</PlainText>
      </Password>
    </LocalAccount>
  </LocalAccounts>
</UserAccounts>
```

### AutoLogon (for FirstLogonCommands to execute)

```xml
<AutoLogon>
  <Enabled>true</Enabled>
  <Username>testuser</Username>
  <Password>
    <Value>TestPass123!</Value>
    <PlainText>true</PlainText>
  </Password>
  <LogonCount>1</LogonCount>
</AutoLogon>
```

---

## FirstLogonCommands

Runs once at first user logon in the oobeSystem pass. Each `<SynchronousCommand>` runs in order.

Known issues:
- Commands may execute asynchronously in some Windows builds despite the name "Synchronous".
  Chain dependent commands with `&&` on a single line or use a wrapper batch script.
- PowerShell execution policy may block scripts. Use `powershell -ExecutionPolicy Bypass -Command "..."`.
- Network may not be ready immediately at first logon. Add delays or retry logic for network-dependent commands.
- winget may not be available until Microsoft Store initializes. Fall back to direct MSI download.

### OpenSSH Server Installation

```xml
<SynchronousCommand wcm:action="add">
  <Order>1</Order>
  <CommandLine>powershell -ExecutionPolicy Bypass -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Start-Service sshd; Set-Service sshd -StartupType Automatic"</CommandLine>
  <Description>Install and enable OpenSSH Server</Description>
</SynchronousCommand>
```

### Static IP Configuration

```xml
<SynchronousCommand wcm:action="add">
  <Order>2</Order>
  <CommandLine>powershell -ExecutionPolicy Bypass -Command "New-NetIPAddress -InterfaceAlias 'Ethernet' -IPAddress 192.168.50.200 -PrefixLength 24 -DefaultGateway 192.168.50.1; Set-DnsClientServerAddress -InterfaceAlias 'Ethernet' -ServerAddresses 8.8.8.8"</CommandLine>
  <Description>Set static IP address</Description>
</SynchronousCommand>
```

Note: The interface name 'Ethernet' assumes virtio-net names it this way. If NetKVM driver
names it differently, use `Get-NetAdapter` to find the actual name. Consider using
`Get-NetAdapter | Where-Object {$_.Status -eq 'Up'} | Select-Object -First 1` for robustness.

### Tailscale Installation (Direct MSI, winget fallback)

winget is unreliable at first logon. Prefer direct MSI download:

```xml
<SynchronousCommand wcm:action="add">
  <Order>3</Order>
  <CommandLine>powershell -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-arm64.msi' -OutFile C:\Windows\Temp\tailscale.msi; Start-Process msiexec.exe -ArgumentList '/i','C:\Windows\Temp\tailscale.msi','/quiet','/norestart' -Wait"</CommandLine>
  <Description>Download and install Tailscale</Description>
</SynchronousCommand>
```

### Automatic Shutdown After Setup

To signal build completion:

```xml
<SynchronousCommand wcm:action="add">
  <Order>99</Order>
  <CommandLine>shutdown /s /t 30 /c "Base image build complete"</CommandLine>
  <Description>Shut down after all setup commands complete</Description>
</SynchronousCommand>
```

---

## Windows 11 Requirement Bypasses

Windows 11 enforces TPM 2.0, Secure Boot, and hardware checks that fail in VMs.
Bypass via registry in windowsPE pass:

```xml
<RunSynchronous>
  <RunSynchronousCommand wcm:action="add">
    <Order>1</Order>
    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
  </RunSynchronousCommand>
  <RunSynchronousCommand wcm:action="add">
    <Order>2</Order>
    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
  </RunSynchronousCommand>
  <RunSynchronousCommand wcm:action="add">
    <Order>3</Order>
    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
  </RunSynchronousCommand>
  <RunSynchronousCommand wcm:action="add">
    <Order>4</Order>
    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
  </RunSynchronousCommand>
  <RunSynchronousCommand wcm:action="add">
    <Order>5</Order>
    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
  </RunSynchronousCommand>
</RunSynchronous>
```

---

## Product Keys (Generic/KMS)

For unattended install, a product key is required in the answer file. Use generic KMS client keys
(these activate against a KMS server or can be changed later):

| Edition | Key |
|---------|-----|
| Windows 11 Pro | W269N-WFGWX-YVC9B-4J6C9-T83GX |
| Windows 11 Home | TX9XD-98N7V-6WMQ6-BX7FG-H8Q99 |
| Windows 11 Enterprise | NPPR9-FWDCX-D2C8J-H872K-2YT43 |

Place in windowsPE pass under `<UserData><ProductKey><Key>`:

```xml
<UserData>
  <ProductKey>
    <Key>W269N-WFGWX-YVC9B-4J6C9-T83GX</Key>
  </ProductKey>
  <AcceptEula>true</AcceptEula>
</UserData>
```

---

## Image Selection

For multi-edition ISOs, specify which edition to install:

```xml
<ImageInstall>
  <OSImage>
    <InstallFrom>
      <MetaData wcm:action="add">
        <Key>/IMAGE/NAME</Key>
        <Value>Windows 11 Pro</Value>
      </MetaData>
    </InstallFrom>
    <InstallTo>
      <DiskID>0</DiskID>
      <PartitionID>3</PartitionID>
    </InstallTo>
  </OSImage>
</ImageInstall>
```

Available editions in consumer ISO: Windows 11 Home, Windows 11 Pro, Windows 11 Education, etc.
If `<InstallFrom>` is omitted and a product key is provided, Windows selects the matching edition.

---

## Complete Autounattend.xml Template (ARM64 UEFI + VirtIO)

```xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

  <!-- ============================================================ -->
  <!-- PASS 1: windowsPE - disk, drivers, image selection           -->
  <!-- ============================================================ -->
  <settings pass="windowsPE">

    <!-- Locale for setup UI -->
    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="arm64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

    <!-- Disk partitioning + image install -->
    <component name="Microsoft-Windows-Setup"
               processorArchitecture="arm64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">

      <!-- Bypass Win11 hardware checks -->
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>5</Order>
          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>

      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Size>100</Size>
              <Type>EFI</Type>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Size>16</Size>
              <Type>MSR</Type>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Extend>true</Extend>
              <Type>Primary</Type>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Format>FAT32</Format>
              <Label>System</Label>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>2</PartitionID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>3</Order>
              <PartitionID>3</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
              <Letter>C</Letter>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
        <WillShowUI>OnError</WillShowUI>
      </DiskConfiguration>

      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/NAME</Key>
              <Value>Windows 11 Pro</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>

      <UserData>
        <ProductKey>
          <Key>W269N-WFGWX-YVC9B-4J6C9-T83GX</Key>
        </ProductKey>
        <AcceptEula>true</AcceptEula>
      </UserData>
    </component>

    <!-- VirtIO driver injection during WinPE -->
    <component name="Microsoft-Windows-PnpCustomizationsWinPE"
               processorArchitecture="arm64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1">
          <Path>E:\vioscsi\w11\ARM64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2">
          <Path>E:\viostor\w11\ARM64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3">
          <Path>E:\NetKVM\w11\ARM64</Path>
        </PathAndCredentials>
      </DriverPaths>
    </component>
  </settings>

  <!-- ============================================================ -->
  <!-- PASS 3: specialize - machine-specific config                  -->
  <!-- ============================================================ -->
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="arm64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <ComputerName>WINVM</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>

  <!-- ============================================================ -->
  <!-- PASS 7: oobeSystem - user accounts, OOBE skip, first-run     -->
  <!-- ============================================================ -->
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="arm64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="arm64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>

      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>testuser</Name>
            <DisplayName>Test User</DisplayName>
            <Group>Administrators</Group>
            <Password>
              <Value>TestPass123!</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>

      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>testuser</Username>
        <Password>
          <Value>TestPass123!</Value>
          <PlainText>true</PlainText>
        </Password>
        <LogonCount>1</LogonCount>
      </AutoLogon>

      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>powershell -ExecutionPolicy Bypass -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Start-Service sshd; Set-Service sshd -StartupType Automatic"</CommandLine>
          <Description>Install and enable OpenSSH Server</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <CommandLine>powershell -ExecutionPolicy Bypass -Command "$a = Get-NetAdapter | Where-Object {$_.Status -eq 'Up'} | Select-Object -First 1; New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress 192.168.50.200 -PrefixLength 24 -DefaultGateway 192.168.50.1; Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses 8.8.8.8"</CommandLine>
          <Description>Set static IP address</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <CommandLine>powershell -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-arm64.msi' -OutFile C:\Windows\Temp\tailscale.msi; Start-Process msiexec.exe -ArgumentList '/i','C:\Windows\Temp\tailscale.msi','/quiet','/norestart' -Wait"</CommandLine>
          <Description>Download and install Tailscale</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>99</Order>
          <CommandLine>shutdown /s /t 30 /c "Base image build complete"</CommandLine>
          <Description>Shut down after setup complete</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
```

---

## Troubleshooting

### Setup Log Locations
- WinPE phase: `X:\Windows\Panther\setupact.log`
- Installed OS: `C:\Windows\Panther\setupact.log` and `C:\Windows\Panther\setuperr.log`
- Unattend processing: `C:\Windows\Panther\UnattendGC\setupact.log`

### Common Failures

| Symptom | Cause | Fix |
|---------|-------|-----|
| "No disks found" at partition step | VirtIO driver not loaded | Add `Microsoft-Windows-PnpCustomizationsWinPE` with driver paths |
| Setup stops at edition selection | No `<ImageInstall>` or wrong edition name | Add `<InstallFrom>` with exact edition name or provide product key |
| OOBE prompts still appear | Wrong `processorArchitecture` in oobeSystem components | Verify `arm64` for ARM64 systems |
| FirstLogonCommands don't run | AutoLogon not configured | Add `<AutoLogon>` section to ensure automatic first login |
| "Windows cannot be installed to this disk" | GPT/UEFI mismatch or wrong partition type | Ensure `<Type>EFI</Type>` for partition 1, verify UEFI boot |
| Commands fail with access denied | Not running as admin | User account must be in Administrators group |
| Tailscale MSI download fails | Network not ready at first logon | Add a sleep/retry or use SetupComplete.cmd instead |

### SetupComplete.cmd Alternative

For commands that need to run after all OOBE processing (more reliable than FirstLogonCommands):

Place at `C:\Windows\Setup\Scripts\SetupComplete.cmd` during specialize pass.
This runs with SYSTEM privileges after OOBE completes but before any user logon.

```xml
<!-- In specialize pass -->
<RunSynchronous>
  <RunSynchronousCommand wcm:action="add">
    <Order>1</Order>
    <Path>cmd /c mkdir C:\Windows\Setup\Scripts</Path>
  </RunSynchronousCommand>
  <RunSynchronousCommand wcm:action="add">
    <Order>2</Order>
    <Path>cmd /c echo powershell -ExecutionPolicy Bypass -File C:\setup-script.ps1 > C:\Windows\Setup\Scripts\SetupComplete.cmd</Path>
  </RunSynchronousCommand>
</RunSynchronous>
```

---

## QEMU-Specific Notes (ARM64)

### Required SMBIOS Serial for Windows Activation
Windows on ARM in QEMU may need a valid-looking SMBIOS serial:
```
-smbios "type=1,serial=76XX5G4"
```

### Display
Use `-device ramfb` for UEFI framebuffer. No virtio-gpu-pci on ARM64 Windows (driver missing).

### USB Controller
Must have XHCI controller for USB devices:
```
-device qemu-xhci
-device usb-kbd
-device usb-tablet
```

### RNG Device
Required for Windows cryptographic operations:
```
-object "rng-random,id=rng0,filename=/dev/urandom"
-device "virtio-rng-pci,rng=rng0"
```

### Clock
Use localtime for Windows:
```
-rtc base=localtime
```
