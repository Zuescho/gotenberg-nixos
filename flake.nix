{
  description = "LAN-only Gotenberg on NixOS for Factur-X / ZUGFeRD";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;

      mkHost =
        extraModules:
        lib.nixosSystem {
          inherit system;
          modules = [
            ./hosts/gotenberg
          ]
          ++ extraModules;
        };

      gotenberg = mkHost [ ];
      direct = mkHost [
        (
          { lib, ... }:
          {
            services.gotenberg-lan.proxy.enable = lib.mkForce false;
          }
        )
      ];
      tls = mkHost [
        (
          { lib, ... }:
          {
            services.gotenberg-lan.proxy.tls.enable = lib.mkForce true;
          }
        )
      ];

      phase1Listen = gotenberg.config.services.nginx.virtualHosts."gotenberg.dueren.de".listen;
      tlsVhost = tls.config.services.nginx.virtualHosts."gotenberg.dueren.de";
      pinnedImage = "docker.io/gotenberg/gotenberg:8.37.0@sha256:3fdee07e0dcd5005c3db4d81d1600d081fc6fb424da87e409e1c1f9624a249b8";

      ok =
        lib.assertMsg (gotenberg.config.networking.hostName == "gotenberg") "hostname is the first label of fqdn"
        && lib.assertMsg (gotenberg.config.networking.domain == "dueren.de") "domain is the rest of fqdn"
        && lib.assertMsg (gotenberg.config.system.stateVersion == "26.05") "stateVersion"
        && lib.assertMsg gotenberg.config.virtualisation.hypervGuest.enable "hyperv guest"
        && lib.assertMsg (gotenberg.config.services.openssh.settings.PasswordAuthentication == false) "ssh keys only"
        && lib.assertMsg gotenberg.config.services.nginx.enable "phase 1 enables nginx"
        && lib.assertMsg (
          lib.any (listen: listen.addr == "10.0.10.20" && listen.port == 80 && listen.ssl == false) phase1Listen
        ) "phase 1 listens on the LAN address port 80"
        && lib.assertMsg (!direct.config.services.nginx.enable) "direct mode does not start nginx"
        && lib.assertMsg (
          direct.config.virtualisation.oci-containers.containers.gotenberg.networks == [ "host" ]
        ) "direct mode uses the host network so the firewall applies"
        && lib.assertMsg (direct.config.virtualisation.oci-containers.containers.gotenberg.ports == [ ])
          "direct mode does not publish a container port"
        && lib.assertMsg tls.config.services.gotenberg-lan.proxy.enable "phase 2 keeps the proxy"
        && lib.assertMsg (lib.any (listen: listen.port == 443 && listen.ssl == true) tlsVhost.listen)
          "phase 2 listens on 443"
        && lib.assertMsg (tlsVhost.sslCertificate == "/var/lib/secrets/gotenberg/fullchain.pem")
          "phase 2 certificate stays outside the Nix store"
        && lib.assertMsg (
          gotenberg.config.virtualisation.oci-containers.containers.gotenberg.image == pinnedImage
        ) "pinned image"
        && lib.assertMsg (
          gotenberg.config.systemd.services.gotenberg.serviceConfig.Restart == "always"
        ) "auto restart";

      assertText =
        name: text: patterns:
        pkgs.runCommand name
          {
            inherit text;
            passAsFile = [ "text" ];
          }
          (
            ''
              set -eu
            ''
            + lib.concatMapStrings (pattern: ''
              grep -F -q -e ${lib.escapeShellArg pattern} "$textPath"
            '') patterns
            + ''
              touch "$out"
            ''
          );
    in
    assert ok;
    {
      nixosModules.gotenberg-lan = ./modules/gotenberg-lan.nix;
      nixosModules.default = self.nixosModules.gotenberg-lan;

      nixosConfigurations = {
        gotenberg = gotenberg;
        gotenberg-direct = direct;
        gotenberg-tls = tls;
      };

      checks.${system} = {
        proxy-flags = assertText "proxy-flags" gotenberg.config.systemd.services.gotenberg.script [
          pinnedImage
          "--api-timeout=120s"
          "--api-body-limit=64MB"
          "--log-level=info"
          "--log-std-format=json"
          "--api-disable-download-from=true"
          "127.0.0.1:3000:3000"
          "/health"
          "--health-on-failure=restart"
          "--memory=2g"
        ];
        proxy-firewall = assertText "proxy-firewall" gotenberg.config.networking.firewall.extraCommands [
          "10.0.20.0/24"
          "--dport 80"
          "--dport 22"
          "gotenberg-lan"
          "ssh-admin"
        ];
        proxy-firewall-closed =
          pkgs.runCommand "proxy-firewall-closed"
            {
              text = gotenberg.config.networking.firewall.extraCommands;
              passAsFile = [ "text" ];
            }
            ''
              set -eu
              if grep -F -q -- '--dport 3000' "$textPath"; then
                echo "API port 3000 is open while the proxy is enabled" >&2
                exit 1
              fi
              if grep -F -q -- '--dport 443' "$textPath"; then
                echo "port 443 is open in phase 1" >&2
                exit 1
              fi
              touch "$out"
            '';
        direct-flags = assertText "direct-flags" direct.config.systemd.services.gotenberg.script [
          "--network=host"
          "--api-bind-ip=10.0.10.20"
          "--api-port=3000"
          "http://10.0.10.20:3000/health"
        ];
        direct-firewall = assertText "direct-firewall" direct.config.networking.firewall.extraCommands [
          "--dport 3000"
          "10.0.20.0/24"
        ];
        tls-firewall = assertText "tls-firewall" tls.config.networking.firewall.extraCommands [
          "--dport 443"
          "--dport 80"
          "10.0.20.0/24"
        ];
        # Same closure nixos-rebuild build produces.
        system = gotenberg.config.system.build.toplevel;
      };
    };
}
