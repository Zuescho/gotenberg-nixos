# Gotenberg on NixOS

LAN-only [Gotenberg](https://gotenberg.dev/) for an ASP.NET ERechnung module running on IIS in the same network. The service turns an invoice PDF plus Factur-X / ZUGFeRD XML into a PDF/A-3 with the embedded XML (`POST /forms/pdfengines/factur-x`).

The VM is a NixOS Generation 2 guest on Windows Hyper-V. Nothing is published to the internet: nginx or Gotenberg binds the internal address, and the firewall accepts that port only from the IIS ranges in `hosts/gotenberg/site.nix`.

## License

Proprietary. All rights reserved. This repository is for internal use by Stadt Düren only.

## Pinned versions

| Piece | Version | Source |
| --- | --- | --- |
| NixOS | 26.05 “Yarara”, `nixos-26.05.11767.7993f34ee47e` | Channel [nixos-26.05](https://channels.nixos.org/nixos-26.05), git [`7993f34ee47e28a3d607a525aadc6c94b73be728`](https://github.com/NixOS/nixpkgs/commit/7993f34ee47e28a3d607a525aadc6c94b73be728), 2026-10-13 |
| Gotenberg | **8.37.0** | [Release v8.37.0](https://github.com/gotenberg/gotenberg/releases/tag/v8.37.0) (2026-09-11) |
| Image | `docker.io/gotenberg/gotenberg:8.37.0` | linux/amd64 `sha256:3fdee07e0dcd5005c3db4d81d1600d081fc6fb424da87e409e1c1f9624a249b8` |

Factur-X form fields (`facturxXml`, `facturxConformanceLevel`) shipped in [v8.34.0](https://github.com/gotenberg/gotenberg/releases/tag/v8.34.0) (2026-06-12). 8.37.0 is the current stable release and still serves `POST /forms/pdfengines/factur-x`.

The multi-arch index for that tag is `sha256:f29984bd1e226bf1b93ba90af06000afa8b315853e99d27b9aaa41b93f15c769`. The module pins the amd64 manifest because the Hyper-V VM is x86_64. Reproduce the lookup with the commands in [docs/operations.md](docs/operations.md).

`flake.lock` records the Nixpkgs revision. `system.autoUpgrade` advances it along `nixos-26.05`.

## What you edit

[hosts/gotenberg/site.nix](hosts/gotenberg/site.nix) holds the FQDN, addresses, IIS subnet, admin SSH key, and the phase switch. The default name is `gotenberg.dueren.de`. `gotenberg.intern.dueren.de` is the split-DNS alternative; a `*.dueren.de` certificate does not cover it. Details are in [docs/hyperv-setup.md](docs/hyperv-setup.md).

## Layout

| Path | Role |
| --- | --- |
| `modules/gotenberg-lan.nix` | `services.gotenberg-lan` on `virtualisation.oci-containers` |
| `hosts/gotenberg/` | Hyper-V guest: networking, SSH, firewall, auto-upgrade, GC, time sync, Podman, Gotenberg |
| `examples/configuration.nix` | Import the module into an existing NixOS host |
| `scripts/hyperv-create-vm.ps1` | Generation 2 VM, Secure Boot off, ISO checksum |
| `scripts/install-from-iso.sh` | GPT + UEFI install of this flake |
| `docs/hyperv-setup.md` | ISO, switch, install, first boot, DNS |
| `docs/tls.md` | Phase 2 wildcard certificate |
| `docs/operations.md` | Upgrade, rollback, checkpoint, `/health` |

## Module

`services.gotenberg-lan` options include `listenAddress`, `port`, `allowedSourceRanges`, `image.tag`, `image.digest`, `timeouts.*`, `bodyLimit`, `log.*`, and `resources.*`. `backend` is `podman` or `docker` (default `podman`).

The container is restarted by systemd (`Restart=always`) and, under Podman, when its health check fails. The check calls `GET /health`. Stdout is JSON in the journal. Defaults are an API timeout of 120 seconds, a 64 MB multipart limit, 2 CPUs, and 2 GB of memory.

Published container ports bypass the NixOS firewall. Direct mode therefore uses the host network and binds `listenAddress`. Proxy mode publishes `127.0.0.1` only and lets nginx face the LAN. The firewall rules are source-specific; the ports are not added to `allowedTCPPorts`.

```nix
# flake.nix of another host
{
  inputs.gotenberg.url = "github:Zuescho/gotenberg-nixos";
  outputs = { self, nixpkgs, gotenberg }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        gotenberg.nixosModules.gotenberg-lan
        ./configuration.nix
      ];
    };
  };
}
```

[examples/configuration.nix](examples/configuration.nix) is the same import without a flake. This repo’s own flake output is `nixosConfigurations.gotenberg`.

## Setup

Follow [docs/hyperv-setup.md](docs/hyperv-setup.md). Short version:

1. Edit `hosts/gotenberg/site.nix` (SSH key, addresses, IIS subnet).
2. Add an internal-only DNS A record for `gotenberg.dueren.de`. Do not publish it.
3. Download the NixOS 26.05 minimal ISO and check the SHA-256 above.
4. Create an external virtual switch on the LAN, then a Generation 2 VM (Secure Boot off, 2 vCPU, 4 GB, 40 GB). `scripts/hyperv-create-vm.ps1` does the VM.
5. Boot the ISO and run `scripts/install-from-iso.sh`.
6. Remove the ISO, start the VM, SSH in with the key.

Phase 1 (default) is HTTP. Phase 2 is the TLS toggle in [docs/tls.md](docs/tls.md).

## Base URL

Set this on the IIS app in `appsettings.Production.json`. No trailing slash. The client appends `/forms/pdfengines/factur-x`. Give `HttpClient` a timeout above 120 seconds (150 seconds is a reasonable start). The body limit is 64 MB.

The JSON property must match the ERechnung options class. The environment-variable form of the example below is `ERechnung__GotenbergBaseUrl`.

Phase 1, proxy on port 80 (this host’s default):

```json
{
  "ERechnung": {
    "GotenbergBaseUrl": "http://gotenberg.dueren.de"
  }
}
```

Phase 1, direct (`httpProxy = false`):

```json
{
  "ERechnung": {
    "GotenbergBaseUrl": "http://gotenberg.dueren.de:3000"
  }
}
```

Phase 2, after the wildcard certificate is installed:

```json
{
  "ERechnung": {
    "GotenbergBaseUrl": "https://gotenberg.dueren.de"
  }
}
```

A public `*.dueren.de` certificate needs no extra trust on Windows. An internal CA must be imported into `Cert:\LocalMachine\Root` on each IIS server. See [docs/tls.md](docs/tls.md).

## Verify

On the VM:

```bash
curl --fail --silent --show-error http://127.0.0.1:3000/health
curl --fail --silent --show-error http://gotenberg.dueren.de/health
sudo podman inspect --format '{{.State.Health.Status}}' gotenberg
```

From an IIS server (phase 1):

```bash
curl --fail --show-error \
  --request POST \
  --form files=@invoice.pdf \
  --form facturxXml=@factur-x.xml \
  --form 'facturxConformanceLevel=EN 16931' \
  --output invoice-facturx.pdf \
  http://gotenberg.dueren.de/forms/pdfengines/factur-x
```

`facturxConformanceLevel` is one of `MINIMUM`, `BASIC WL`, `BASIC`, `EN 16931`, `EXTENDED`, `XRECHNUNG`. The response is the Factur-X PDF. After phase 2, use `https://gotenberg.dueren.de/forms/pdfengines/factur-x`.

A source outside `iisSourceRanges` cannot open the port. There is no application password; the firewall is the access control. `downloadFrom` is disabled.

## Upgrading

NixOS security updates on the stable branch are applied by `system.autoUpgrade` from `/etc/nixos`. Gotenberg upgrades are a new tag and digest in `modules/gotenberg-lan.nix`. Roll back with `nixos-rebuild switch --rollback` or a Hyper-V checkpoint. [docs/operations.md](docs/operations.md) has the commands.
