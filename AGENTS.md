# Rules for coding agents

This repository deploys a LAN-only Gotenberg for Stadt Düren. Follow these rules on every change.

- Never push to `main`. Commit and push only on a feature branch, and open or update a pull request against `main`.
- Host-specific values live only in `hosts/gotenberg/site.nix`. Leave the committed placeholders (`CHANGE_ME`, the `REPLACE_ME` SSH key comment, `10.0.10.20`, `10.0.20.0/24`). Do not commit a real address plan, a real public key that replaces the placeholder on `main`'s history without a request to do so, a password hash, or anything from `/var/lib/secrets`.
- Do not add a `LICENSE` file. The maintainer is choosing the license. The README states the current terms.
- Do not publish the Gotenberg port on a non-loopback address. Proxy mode publishes `127.0.0.1` only. Direct mode uses the host network and `--api-bind-ip`. The firewall, not `allowedTCPPorts`, is the access control.
- Factur-X examples use `POST /forms/pdfengines/factur-x` with `facturxXml` and `facturxConformanceLevel` set to `EN 16931` or `XRECHNUNG`.
- Format Nix with `nix fmt`. The flake `formatter` output is `nixfmt-tree` (nixfmt 1.5, RFC 166, the package formerly called `nixfmt-rfc-style`).
- Before you finish, run `nix flake check` and `nix build .#nixosConfigurations.gotenberg.config.system.build.toplevel`. `nix flake check` includes the NixOS closure and `nixfmt --check`.
- Flakes only see tracked files. `git add` Nix changes before those commands.
