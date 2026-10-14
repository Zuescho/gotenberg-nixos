# Create a Generation 2 Hyper-V VM for the Gotenberg NixOS host.
# Run from an elevated PowerShell session on the Hyper-V server.
#
#   .\scripts\hyperv-create-vm.ps1 -SwitchName "LAN" -IsoPath C:\ISO\nixos-minimal.iso
#
# Optional ISO download and checksum:
#   .\scripts\hyperv-create-vm.ps1 -SwitchName "LAN" -DownloadIso
param(
    [string]$Name = "gotenberg",
    [string]$SwitchName,
    [string]$IsoPath,
    [switch]$DownloadIso,
    [string]$VhdPath = "C:\Hyper-V\gotenberg\gotenberg.vhdx",
    [uint64]$MemoryBytes = 4GB,
    [int]$ProcessorCount = 2,
    [uint64]$VhdBytes = 40GB,
    [string]$StaticMac = "",
    [string]$IsoUrl = "https://releases.nixos.org/nixos/26.05/nixos-26.05.11767.7993f34ee47e/nixos-minimal-26.05.11767.7993f34ee47e-x86_64-linux.iso",
    [string]$IsoSha256 = "9d29b516f47eabf28ce6d17356a00f15daf3c1a267bbe1357d11a6d82dbe1090"
)

$ErrorActionPreference = "Stop"

if (-not $SwitchName) {
    throw "Pass -SwitchName, the external virtual switch on the LAN (not the Default Switch)."
}

if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw "The Hyper-V PowerShell module is not available. Run this on the Hyper-V host."
}

if ($DownloadIso) {
    if (-not $IsoPath) {
        $IsoPath = Join-Path $env:USERPROFILE "Downloads\nixos-minimal-26.05.11767.7993f34ee47e-x86_64-linux.iso"
    }
    Write-Host "Downloading $IsoUrl"
    Invoke-WebRequest -Uri $IsoUrl -OutFile $IsoPath
}

if (-not $IsoPath) {
    throw "Pass -IsoPath or -DownloadIso."
}
if (-not (Test-Path -LiteralPath $IsoPath)) {
    throw "ISO not found: $IsoPath"
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $IsoPath).Hash.ToLower()
if ($hash -ne $IsoSha256) {
    throw "ISO SHA-256 mismatch.`n  got:      $hash`n  expected: $IsoSha256"
}
Write-Host "ISO checksum matches NixOS 26.05 minimal x86_64."

$switch = Get-VMSwitch -Name $SwitchName
if ($switch.SwitchType -eq "Internal" -or $switch.SwitchType -eq "Private") {
    Write-Warning "$SwitchName is $($switch.SwitchType). IIS servers on the LAN cannot reach a private or internal switch."
}

if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    throw "VM '$Name' already exists."
}

$vhdDir = Split-Path -Parent $VhdPath
New-Item -ItemType Directory -Force -Path $vhdDir | Out-Null

New-VM -Name $Name -Generation 2 -MemoryStartupBytes $MemoryBytes -SwitchName $SwitchName `
    -NewVHDPath $VhdPath -NewVHDSizeBytes $VhdBytes -Path $vhdDir | Out-Null

Set-VMProcessor -VMName $Name -Count $ProcessorCount
Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes $MemoryBytes
Set-VMFirmware -VMName $Name -EnableSecureBoot Off

Add-VMDvdDrive -VMName $Name -Path $IsoPath
$dvd = Get-VMDvdDrive -VMName $Name
$disk = Get-VMHardDiskDrive -VMName $Name
Set-VMFirmware -VMName $Name -BootOrder $dvd, $disk

if ($StaticMac) {
    $mac = ($StaticMac -replace '[:-]', '').ToUpper()
    if ($mac -notmatch '^[0-9A-F]{12}$') {
        throw "StaticMac must be 12 hex digits, optionally separated by ':' or '-'."
    }
    Set-VMNetworkAdapter -VMName $Name -StaticMacAddress $mac
}

# Start after the host boots. Production checkpoints use the guest VSS daemon
# once NixOS and virtualisation.hypervGuest are installed.
Set-VM -Name $Name -AutomaticStartAction Start -AutomaticStopAction ShutDown -CheckpointType Production
Get-VMIntegrationService -VMName $Name | Where-Object { -not $_.Enabled } | Enable-VMIntegrationService

Write-Host ""
Write-Host "VM '$Name' is ready. Start it, then follow the installer section of docs/hyperv-setup.md."
Write-Host "Secure Boot is off. Dynamic memory is off. Disk: $VhdPath"
Get-VM -Name $Name | Format-List Name, Generation, MemoryStartup, ProcessorCount, State
Get-VMNetworkAdapter -VMName $Name | Format-List SwitchName, MacAddress
