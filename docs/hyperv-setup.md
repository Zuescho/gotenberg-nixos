# Hyper-V setup

This installs the Gotenberg host as a NixOS Generation 2 virtual machine on a Windows Hyper-V server. The VM stays on the internal LAN. IIS servers in the configured subnet are the only clients.

Edit [hosts/gotenberg/site.nix](../hosts/gotenberg/site.nix) before the install. That file is the only place for the DNS name, addresses, the IIS subnet, the admin SSH key, and the HTTP/HTTPS switch.

## Versions

| Component | Pin | Source |
| --- | --- | --- |
| NixOS | 26.05 “Yarara”, channel release `nixos-26.05.11767.7993f34ee47e` | [nixos-26.05](https://channels.nixos.org/nixos-26.05), git `7993f34ee47e28a3d607a525aadc6c94b73be728`, published 2026-10-13 |
| Installer ISO | `nixos-minimal-26.05.11767.7993f34ee47e-x86_64-linux.iso` | SHA-256 `9d29b516f47eabf28ce6d17356a00f15daf3c1a267bbe1357d11a6d82dbe1090` |
| Gotenberg | 8.37.0, linux/amd64 digest `sha256:3fdee07e0dcd5005c3db4d81d1600d081fc6fb424da87e409e1c1f9624a249b8` | [v8.37.0](https://github.com/gotenberg/gotenberg/releases/tag/v8.37.0) |

Factur-X (`POST /forms/pdfengines/factur-x`) was added in [v8.34.0](https://github.com/gotenberg/gotenberg/releases/tag/v8.34.0). 8.37.0 is the current stable image and keeps that route. The digest is the amd64 manifest, not the multi-arch index (`sha256:f29984bd1e226bf1b93ba90af06000afa8b315853e99d27b9aaa41b93f15c769`).

The flake follows the `nixos-26.05` branch and locks the revision in `flake.lock`. `system.autoUpgrade` later moves that lock along the same stable branch.

## 1. Fill in site.nix

On a workstation, clone the repository and edit `hosts/gotenberg/site.nix`:

- `fqdn` — default `gotenberg.dueren.de`. This one option is the name nginx, the host, and the base URL use.
- `address`, `prefixLength`, `gateway`, `nameservers` — static LAN plan. The placeholders are documentation values, not a real subnet.
- `iisSourceRanges` — CIDR or addresses of the IIS servers.
- `adminSourceRanges` — CIDR of the machines that may SSH.
- `adminAuthorizedKeys` — your ed25519 public key. Delete the `REPLACE_ME` key. The install script refuses to run while that marker is still inside `adminAuthorizedKeys`.

```bash
ssh-keygen -t ed25519 -C "gotenberg-admin"
```

SSH accepts keys only. A console password is separate and optional:

```bash
nix-shell -p mkpasswd --run 'mkpasswd -m sha-512'
```

Put the hash in `initialHashedPassword` in the copy you install. Leave it `null` to lock console login. Do not push a real hash to a shared remote. The public key may be committed.

`httpProxy = true` and `tls.enable = false` is phase 1: plain HTTP on port 80. Leave TLS off until [tls.md](tls.md).

### DNS name

Create this record on internal DNS only. Do not publish it in the public zone:

```text
gotenberg.dueren.de.   300   IN A   10.0.10.20
```

Use the address from `site.nix`. IIS and the admin workstations must query a resolver that serves this view.

`dueren.de` is also a public name. Internal clients need split-horizon DNS: the domain controllers (or another internal authoritative server) answer `gotenberg.dueren.de` with the private address, and the public zone has no such record. A client that uses a public resolver will not see an internal-only name.

`gotenberg.intern.dueren.de` avoids sharing the public zone. Create a zone `intern.dueren.de` that exists only on internal DNS, and set `fqdn` to that name. A certificate for `*.dueren.de` does not match a name with an extra label. Phase 2 would need a certificate that covers `gotenberg.intern.dueren.de`. The default stays `gotenberg.dueren.de` because the existing wildcard already matches it.

### DHCP reservation instead of a static address

Set `useStaticAddress = false` and `listenAddress = "0.0.0.0"`. Give the VM a static MAC in the script (`-StaticMac`) and reserve that MAC on the Windows DHCP server. The firewall source list still applies. Binding a specific address is preferable when the address is known at install time.

## 2. Download the ISO and check it

The minimal x86_64 ISO is about 1.6 GiB (1739718656 bytes).

```powershell
$isoUrl = "https://releases.nixos.org/nixos/26.05/nixos-26.05.11767.7993f34ee47e/nixos-minimal-26.05.11767.7993f34ee47e-x86_64-linux.iso"
$iso = "$env:USERPROFILE\Downloads\nixos-minimal-26.05.11767.7993f34ee47e-x86_64-linux.iso"
Invoke-WebRequest -Uri $isoUrl -OutFile $iso
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $iso).Hash.ToLower()
$expected = "9d29b516f47eabf28ce6d17356a00f15daf3c1a267bbe1357d11a6d82dbe1090"
if ($hash -ne $expected) { throw "checksum mismatch: $hash" }
```

The same checksum is published beside the ISO as `nixos-minimal-26.05.11767.7993f34ee47e-x86_64-linux.iso.sha256` on `https://channels.nixos.org/nixos-26.05/`. The channel URL `latest-nixos-minimal-x86_64-linux.iso` redirects at the current stable ISO. Re-check the hash if you follow that redirect later, because the channel moves.

`scripts/hyperv-create-vm.ps1 -DownloadIso` downloads this ISO and checks the hash before it creates the VM.

## 3. Virtual switch

Create an **external** virtual switch bound to the physical NIC that faces the LAN. IIS servers must reach the VM at its LAN address. The Hyper-V “Default Switch” is NAT and is the wrong network.

Hyper-V Manager: Virtual Switch Manager → New virtual network switch → External → the LAN adapter. Allow the management operating system to share the adapter if this host also needs that NIC.

```powershell
New-VMSwitch -Name "LAN" -NetAdapterName "Ethernet" -AllowManagementOS $true
```

Use the real adapter name from `Get-NetAdapter`.

## 4. Create the Generation 2 VM

Sizing for Factur-X on the pinned image:

| Setting | Value | Why |
| --- | --- | --- |
| Generation | 2 | UEFI, required by the partitioning in the install script |
| Secure Boot | Off | The NixOS ISO and systemd-boot are not signed for the Hyper-V Secure Boot template |
| vCPU | 2 | Enough for qpdf Factur-X. Raise it if the same host also converts Office documents |
| Memory | 4 GB, dynamic memory off | The container limit is 2 GB. The rest is NixOS and the page cache. The balloon driver fights a moving target |
| Disk | 40 GB VHDX | Nix store plus the Gotenberg image (Chromium and LibreOffice) |
| NIC | External LAN switch | Same L2 network as the IIS servers |
| MAC | Dynamic, or static | Static only if DHCP reservation is used |
| Checkpoints | Production | Uses the guest VSS components once `virtualisation.hypervGuest` is up |
| Automatic start | Start | The VM comes back when the Hyper-V host boots |

Integration services stay enabled. They are on by default for Generation 2.

### PowerShell

From an elevated session, in a clone of this repo:

```powershell
.\scripts\hyperv-create-vm.ps1 -SwitchName "LAN" -IsoPath $iso
# optional reservation:
# .\scripts\hyperv-create-vm.ps1 -SwitchName "LAN" -IsoPath $iso -StaticMac "00-15-5D-01-02-03"
```

### Hyper-V Manager

1. New → Virtual Machine.
2. Generation 2.
3. Startup memory 4096 MB. Uncheck “Use Dynamic Memory”.
4. Connection: the external LAN switch.
5. Create a 40 GB virtual hard disk.
6. Install from the ISO checked above.
7. After the wizard: Settings → Security → uncheck Enable Secure Boot.
8. Settings → Processor → 2 virtual processors.
9. Firmware → boot from DVD first, then the hard disk.
10. Optional: Network Adapter → Advanced → static MAC.

## 5. Install NixOS

Start the VM and connect to the console. The installer is root with no password.

If the keyboard is German:

```bash
loadkeys de
```

Confirm the virtual disk. It is usually `/dev/sda`. The ISO is a different device. Do not partition the ISO.

```bash
lsblk
```

The installer needs outbound HTTPS to GitHub, `cache.nixos.org`, and `registry-1.docker.io` (the image is pulled on first boot). DHCP on the installer is enough when the LAN has DHCP. The installed system then switches to the static address from `site.nix`.

Without DHCP, set a temporary address so the installer can download Nixpkgs:

```bash
ip link set eth0 up
ip addr add 10.0.10.20/24 dev eth0
ip route add default via 10.0.10.1
printf 'nameserver 10.0.10.1\n' > /etc/resolv.conf
```

Use the real gateway and DNS. Enable flakes and clone the repo you edited:

```bash
mkdir -p /etc/nix
printf 'experimental-features = nix-command flakes\n' >> /etc/nix/nix.conf
nix-shell -p git --run 'git clone https://github.com/Zuescho/gotenberg-nixos.git /root/gotenberg-nixos'
```

If `site.nix` was edited on a workstation and not pushed, copy that file onto the ISO (`scp` from the workstation to the installer) over the clone. The install copies the whole directory to `/etc/nixos`, including `.git`, so later lockfile updates can be committed.

```bash
nano /root/gotenberg-nixos/hosts/gotenberg/site.nix
CONFIRM=yes DISK=/dev/sda REPO=/root/gotenberg-nixos \
  bash /root/gotenberg-nixos/scripts/install-from-iso.sh
```

The script:

1. Refuses to run while the SSH key still says `REPLACE_ME`.
2. Writes a GPT label, a 512 MiB ESP (`NIXBOOT`), and an ext4 root (`NIXROOT`).
3. Copies the repo to `/mnt/etc/nixos`.
4. Runs `nixos-install --flake /mnt/etc/nixos#gotenberg`.

`hosts/gotenberg/hardware-configuration.nix` mounts those labels and installs systemd-boot. `virtualisation.hypervGuest.enable` puts `hv_vmbus`, `hv_storvsc`, `hv_netvsc`, `hv_utils`, and `hv_balloon` in the initrd and starts the Hyper-V guest daemons.

If `nixos-install` cannot write EFI variables, set `boot.loader.efi.canTouchEfiVariables = false` in the hardware file and rerun the install. Generation 2 normally accepts the variable update.

## 6. First boot

Shut the VM down, remove the ISO so the next start boots the disk, then start it.

```powershell
Stop-VM -Name gotenberg -Force
Get-VMDvdDrive -VMName gotenberg | Remove-VMDvdDrive
Start-VM -Name gotenberg
```

There is no root password. Log in with the SSH key. Password authentication is disabled, including when `initialHashedPassword` is set. That hash is only for the Hyper-V console.

```powershell
ssh -i $env:USERPROFILE\.ssh\id_ed25519 admin@10.0.10.20
```

From the VM:

```bash
ip -4 addr show eth0
systemctl status gotenberg
systemctl status nginx
curl --fail --silent --show-error http://127.0.0.1:3000/health
curl --fail --silent --show-error http://gotenberg.dueren.de/health
```

`/etc/hosts` maps the static address to the FQDN so the second command works before internal DNS is delegated. IIS still needs the real DNS record.

Gotenberg’s unit stays in `activating` until the container health check passes, which includes the first image pull. `journalctl -u gotenberg -e` shows the pull and the JSON logs.

From a machine in `iisSourceRanges`:

```bash
curl --fail --silent --show-error http://gotenberg.dueren.de/health
```

A client outside that list gets no TCP handshake (the firewall drops the new connection). Port 3000 is not open in phase 1. The container publishes `127.0.0.1:3000` only, because a published container port would bypass the NixOS firewall.

## 7. Base URL for the ERechnung app

Phase 1, this host’s default (`httpProxy = true`):

```text
http://gotenberg.dueren.de
```

No trailing slash. The ASP.NET client appends `/forms/pdfengines/factur-x`. Set the HttpClient timeout above the Gotenberg API timeout (120 seconds), for example 150 seconds. Uploads larger than 64 MB are rejected.

```json
{
  "ERechnung": {
    "GotenbergBaseUrl": "http://gotenberg.dueren.de"
  }
}
```

The property name has to match the options class in the ERechnung module. The environment variable form is `ERechnung__GotenbergBaseUrl`.

Direct mode (`httpProxy = false` in `site.nix`, then rebuild) uses:

```text
http://gotenberg.dueren.de:3000
```

Phase 2 (`tls.enable = true` after the certificate is installed) uses:

```text
https://gotenberg.dueren.de
```

Details, the PFX conversion, and the IIS trust store are in [tls.md](tls.md). Upgrades, rollback, checkpoints, and `/health` are in [operations.md](operations.md).
