# Import the module into an existing NixOS host.
# The turnkey Hyper-V VM is hosts/gotenberg instead of this file.
#
# Flake:
#   inputs.gotenberg.url = "github:Zuescho/gotenberg-nixos";
#   imports = [ inputs.gotenberg.nixosModules.gotenberg-lan ];
#
# Channel / path:
#   imports = [ /etc/nixos/modules/gotenberg-lan.nix ];
{ ... }:
{
  imports = [ ../modules/gotenberg-lan.nix ];

  services.gotenberg-lan = {
    enable = true;
    fqdn = "gotenberg.dueren.de";
    listenAddress = "10.0.10.20";
    port = 3000;
    allowedSourceRanges = [ "10.0.20.0/24" ];

    # Phase 1. Gotenberg listens on 127.0.0.1:3000, nginx on port 80.
    proxy.enable = true;
    # Phase 2. Put the PEM files in place first, then flip this on.
    # proxy.tls.enable = true;

    timeouts.api = "120s";
    bodyLimit = "64MB";
  };
}
