# Operations

The running configuration is the Git checkout at `/etc/nixos` on the VM. Rebuilds use the `gotenberg` flake output.

```bash
sudo nixos-rebuild switch --flake /etc/nixos#gotenberg
```

## Upgrade NixOS

`system.autoUpgrade` runs daily at about 02:15 (plus up to 30 minutes of delay). It updates the `nixpkgs` input of `/etc/nixos` along the `nixos-26.05` branch, commits the lockfile as root, and switches. A reboot is allowed only between 01:00 and 05:00, and only when the new generation changes the kernel or initrd.

The timer needs outbound HTTPS to GitHub and `cache.nixos.org`. A failed run leaves the booted generation in place. `systemctl status nixos-upgrade.service` and `journalctl -u nixos-upgrade` show the last attempt.

To upgrade by hand:

```bash
cd /etc/nixos
sudo nix flake update nixpkgs
sudo nixos-rebuild switch --flake /etc/nixos#gotenberg
```

Stay on `nixos-26.05` until you intentionally move the input URL. That branch is the stable release (26.05 “Yarara”).

Garbage collection runs on Sundays at 05:30 and deletes store paths older than 14 days. Generations from the last two weeks remain available for rollback. It does not run in the same window as the upgrade timer.

## Upgrade Gotenberg

The image is pinned in `modules/gotenberg-lan.nix` (`image.tag` and `image.digest`). Factur-X requires 8.34.0 or newer. The route is `POST /forms/pdfengines/factur-x`.

1. Read the release notes on <https://github.com/gotenberg/gotenberg/releases>.
2. Resolve the new linux/amd64 digest:

```bash
TOKEN=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:gotenberg/gotenberg:pull" | jq -r .token)
curl -fsSI -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
  "https://registry-1.docker.io/v2/gotenberg/gotenberg/manifests/8.37.0" \
  | awk 'tolower($1)=="docker-content-digest:" { print $2 }'
```

That header is the multi-arch index. The VM is x86_64, so pin the manifest whose platform is `linux/amd64` inside that index. The current 8.37.0 values are recorded in the README.

3. Change `image.tag` and `image.digest` in the module, commit, and pull on the VM (or edit `/etc/nixos` directly).
4. Checkpoint the VM, then:

```bash
sudo nixos-rebuild switch --flake /etc/nixos#gotenberg
systemctl status gotenberg
scripts/check-health.sh http://127.0.0.1:3000/health
```

Podman pulls the new digest because the image reference changed. The previous image stays in `/var/lib/containers` until Podman prunes it. `nix.gc` only deletes Nix store paths and does not remove OCI images.

`virtualisation.podman.autoPrune` runs `podman system prune -f --all --filter until=336h` on Sundays at 05:40. Unused images older than 14 days are deleted. The image of a running container is kept. To free space immediately after an upgrade:

```bash
sudo podman system prune -f --all --filter until=336h
```

A NixOS rollback within those 14 days still has the previous image locally. An older rollback pulls that digest again.

You can override the pin without editing the module:

```nix
services.gotenberg-lan.image.tag = "8.37.0";
services.gotenberg-lan.image.digest = "sha256:...";
```

Put that override in the host config, not in a second copy of the secrets.

## Rollback

NixOS keeps previous generations:

```bash
sudo nixos-rebuild switch --rollback
# or pick one:
nixos-rebuild list-generations
sudo nixos-rebuild switch --flake /etc/nixos#gotenberg
```

The bootloader menu (spam `Esc` or the space bar on the Hyper-V console during systemd-boot) boots an older generation once. That does not change the default. Run `--rollback` to make it stick.

A rollback restores the Gotenberg unit and nginx config from that generation. It does not restore PEM files you overwrote under `/var/lib/secrets`, and it does not restore a Hyper-V disk from before the upgrade. Use a checkpoint for those.

## Hyper-V checkpoint

Take a checkpoint before an image upgrade, a NixOS channel move, or a certificate replacement.

```powershell
Checkpoint-VM -Name gotenberg -SnapshotName "before-upgrade-$(Get-Date -Format yyyyMMdd-HHmm)"
```

The VM is set to production checkpoints. `virtualisation.hypervGuest.enable` starts the Hyper-V VSS daemon, so a production checkpoint asks the guest to freeze the filesystem. If a production checkpoint fails (guest components not running yet), create a standard one while the VM is shut down:

```powershell
Stop-VM -Name gotenberg
Set-VM -Name gotenberg -CheckpointType Standard
Checkpoint-VM -Name gotenberg -SnapshotName "offline-before-upgrade"
Set-VM -Name gotenberg -CheckpointType Production
Start-VM -Name gotenberg
```

Restore only when a generation rollback is not enough. Restoring a checkpoint discards every disk write since the checkpoint, including newer lockfiles and certificates.

```powershell
Restore-VMCheckpoint -Name "before-upgrade-..." -VMName gotenberg -Confirm:$false
Start-VM -Name gotenberg
```

Remove checkpoints after the new generation has passed a Factur-X request. They consume disk on the Hyper-V host.

```powershell
Remove-VMCheckpoint -VMName gotenberg -Name "before-upgrade-..."
```

This is the backup of the VM disk. It is not a backup of the Git history. Push commits of `site.nix` and the image pin from a workstation. Do not push private keys or a password hash.

## Health and logs

| Check | Command |
| --- | --- |
| Process inside the container | `curl --fail --silent --show-error http://127.0.0.1:3000/health` |
| Phase 1 URL | `curl --fail --silent --show-error http://gotenberg.dueren.de/health` |
| Phase 2 URL | `curl --fail --silent --show-error https://gotenberg.dueren.de/health` |
| Container health | `sudo podman inspect --format '{{.State.Health.Status}}' gotenberg` |
| Unit | `systemctl status gotenberg nginx` |
| API logs | `journalctl -u gotenberg -e` |

`scripts/check-health.sh` wraps the curl. `/health` returns HTTP 200 when the API is up. The proxy does not write an access log line for that path.

The unit restarts on failure (`Restart=always`). Podman also restarts the container when the health check fails (`--health-on-failure=restart`). A probe during a planned Chromium or LibreOffice recycle stays successful on 8.37.0; an unplanned crash does not.

JSON logs use `--log-level=info` and `--log-std-format=json`. Health-check telemetry is off so probes do not fill the journal. The journal is capped at 500 MB and two weeks.

A monitor on an IIS server, or on the admin network, should request the same URL the app uses and alert on a non-200 or a timeout. Restrict the monitor’s address by adding it to `iisSourceRanges` or it will be dropped by the firewall.

Sample conversion, from an allowed source:

```bash
curl --fail --show-error \
  --request POST \
  --form files=@invoice.pdf \
  --form facturxXml=@factur-x.xml \
  --form 'facturxConformanceLevel=EN 16931' \
  --output invoice-facturx.pdf \
  http://gotenberg.dueren.de/forms/pdfengines/factur-x
```

Use `https://` and no explicit port after phase 2. Conformance levels: `MINIMUM`, `BASIC WL`, `BASIC`, `EN 16931`, `EXTENDED`, `XRECHNUNG`.

## Clock

`systemd-timesyncd` is enabled (`time.timeZone` from `site.nix`, default `Europe/Berlin`). Hyper-V can also step the clock through `hv_utils`. If the clock oscillates, disable the Hyper-V “Time Synchronization” integration service and keep timesyncd:

```powershell
Disable-VMIntegrationService -VMName gotenberg -Name "Time Synchronization"
```

## What stays closed

- The API is not on a public interface and has no application login. Access control is the source firewall.
- `downloadFrom` is disabled, so Gotenberg does not fetch URLs on behalf of a caller.
- SSH is key-only and limited to `adminSourceRanges`.
- Ports 80, 443, and 3000 are not in `allowedTCPPorts`. Adding them there would accept every source.
