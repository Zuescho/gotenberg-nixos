## Summary

## Checks

- [ ] `nix fmt`
- [ ] `nix flake check`
- [ ] `nix build .#nixosConfigurations.gotenberg.config.system.build.toplevel`
- [ ] `hosts/gotenberg/site.nix` still has the placeholders (`CHANGE_ME`, `REPLACE_ME`). No real addresses, password hash, or TLS material.
- [ ] No `LICENSE` file added.

## Notes
