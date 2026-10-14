# Contributing

Changes land through a pull request into `main`. Do not push to `main`.

The repository is for internal use by Stadt Düren. Do not add a `LICENSE` file; the maintainer is choosing one. The README states the current terms.

## What belongs in git

`hosts/gotenberg/site.nix` is the only file for the DNS name, addresses, IIS subnet, admin SSH key, and the HTTP/HTTPS switch. The copy in git keeps the placeholders (`CHANGE_ME`, `REPLACE_ME`). Put the real LAN plan in the checkout you install, and do not push that copy to a shared remote.

Never commit:

- TLS material (`*.pem`, `*.key`, `*.pfx`, `*.p12`) or a `secrets/` directory
- a console password hash
- an SSH private key
- Nix build symlinks (`result`, `result-*`)

## Checks

Format, then evaluate and build:

```bash
nix fmt
nix flake check
nix build .#nixosConfigurations.gotenberg.config.system.build.toplevel
```

`nix fmt` uses the flake `formatter` output, which is nixfmt 1.5 (RFC 166). `nix flake check` builds the NixOS configuration and fails when a Nix file is not formatted. GitHub Actions runs the same three steps on every pull request.

`git add` the Nix files before those commands. A flake does not see untracked files.

The placeholder SSH key warning during evaluation is expected until `adminAuthorizedKeys` is replaced on the machine you install.

## Pull requests

Describe what changed and how you checked it. Say whether `site.nix` still contains only placeholders. Do not include invoice XML, certificates, or customer data in the description or in screenshots.
