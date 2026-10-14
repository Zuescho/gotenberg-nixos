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

      # Companion configs force the phase under test. Site values (address,
      # fqdn, image pin, source ranges) still come from hosts/gotenberg/site.nix
      # and the module defaults, so editing those does not fail evaluation.
      gotenberg = mkHost [ ];
      direct = mkHost [
        (
          { lib, ... }:
          {
            services.gotenberg-lan.proxy.enable = lib.mkForce false;
            services.gotenberg-lan.proxy.tls.enable = lib.mkForce false;
          }
        )
      ];
      tls = mkHost [
        (
          { lib, ... }:
          {
            services.gotenberg-lan.proxy.enable = lib.mkForce true;
            services.gotenberg-lan.proxy.tls.enable = lib.mkForce true;
          }
        )
      ];

      cfgOf = host: host.config.services.gotenberg-lan;

      imageRef =
        cfg:
        if cfg.image.digest == "" then
          "${cfg.image.repository}:${cfg.image.tag}"
        else
          "${cfg.image.repository}:${cfg.image.tag}@${cfg.image.digest}";

      fqdnParts = cfg: lib.splitString "." cfg.fqdn;

      clientPorts =
        cfg:
        if !cfg.proxy.enable then
          [ cfg.port ]
        else if cfg.proxy.tls.enable then
          [
            80
            443
          ]
        else
          [ 80 ];

      # Short-circuit: a disabled proxy, or phase 2, never looks up the phase 1 vhost.
      phase1Ok =
        host:
        let
          cfg = cfgOf host;
        in
        (!cfg.proxy.enable || cfg.proxy.tls.enable)
        || (
          host.config.services.nginx.enable
          && (
            let
              vhost = host.config.services.nginx.virtualHosts.${cfg.fqdn};
            in
            lib.any (
              listen: listen.addr == cfg.listenAddress && listen.port == 80 && listen.ssl == false
            ) vhost.listen
          )
        );

      tlsOk =
        host:
        let
          cfg = cfgOf host;
        in
        (!cfg.proxy.tls.enable)
        || (
          cfg.proxy.enable
          && host.config.services.nginx.enable
          && (
            let
              vhost = host.config.services.nginx.virtualHosts.${cfg.fqdn};
            in
            lib.any (listen: listen.addr == cfg.listenAddress && listen.port == 443 && listen.ssl == true) vhost.listen
            && vhost.sslCertificate == cfg.proxy.tls.certificate
            && vhost.sslCertificateKey == cfg.proxy.tls.key
          )
        );

      container = host: host.config.virtualisation.oci-containers.containers.gotenberg;

      directShapeOk =
        host:
        let
          cfg = cfgOf host;
          c = container host;
        in
        cfg.proxy.enable
        || (
          !host.config.services.nginx.enable
          && c.networks == [ "host" ]
          && c.ports == [ ]
          && c.image == imageRef cfg
        );

      ok =
        let
          cfg = cfgOf gotenberg;
          parts = fqdnParts cfg;
        in
        lib.assertMsg (gotenberg.config.networking.hostName == lib.head parts) "hostname is the first label of fqdn"
        && lib.assertMsg (
          gotenberg.config.networking.domain == lib.concatStringsSep "." (lib.tail parts)
        ) "domain is the rest of fqdn"
        && lib.assertMsg (gotenberg.config.system.stateVersion == "26.05") "stateVersion"
        && lib.assertMsg gotenberg.config.virtualisation.hypervGuest.enable "hyperv guest"
        && lib.assertMsg (gotenberg.config.services.openssh.settings.PasswordAuthentication == false) "ssh keys only"
        && lib.assertMsg (phase1Ok gotenberg) "phase 1 listens on the configured LAN address port 80"
        && lib.assertMsg (directShapeOk direct) "direct mode uses the host network and does not publish a port"
        && lib.assertMsg (tlsOk tls) "phase 2 listens on 443 with the configured certificate paths"
        && lib.assertMsg ((container gotenberg).image == imageRef cfg) "container image follows services.gotenberg-lan.image"
        && lib.assertMsg (
          gotenberg.config.systemd.services.gotenberg.serviceConfig.Restart == "always"
        ) "auto restart"
        && lib.assertMsg gotenberg.config.virtualisation.podman.autoPrune.enable
          "podman prunes unused images; nix.gc does not";

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

      fwOf =
        host:
        let
          fw = host.config.networking.firewall;
        in
        {
          backend = fw.backend;
          text = if fw.backend == "nftables" then fw.extraInputRules else fw.extraCommands;
        };

      # iptables emits one --dport per port. nftables emits one set per rule.
      dportPatterns =
        backend: ports:
        if backend == "nftables" then
          [ "tcp dport { ${lib.concatMapStringsSep ", " toString ports} }" ]
        else
          map (port: "--dport ${toString port}") ports;

      sourcePatterns =
        cfg:
        cfg.allowedSourceRanges
        ++ lib.optional (
          cfg.listenAddress != "0.0.0.0" && cfg.listenAddress != "127.0.0.1"
        ) "${cfg.listenAddress}/32";

      scriptPatterns =
        host:
        let
          c = container host;
        in
        [ c.image ] ++ c.cmd ++ c.extraOptions ++ c.ports ++ map (net: "--network=${net}") c.networks;

      forbidPorts =
        name: host: ports:
        let
          fw = fwOf host;
        in
        pkgs.runCommand name
          {
            text = fw.text;
            passAsFile = [ "text" ];
          }
          (
            ''
              set -eu
            ''
            + lib.concatMapStrings (port: ''
              if grep -E -q ${
                lib.escapeShellArg (
                  if fw.backend == "nftables" then
                    "(^|[^0-9])${toString port}([^0-9]|$)"
                  else
                    "--dport ${toString port}([^0-9]|$)"
                )
              } "$textPath"; then
                echo "port ${toString port} is open in ${name}" >&2
                exit 1
              fi
            '') ports
            + ''
              touch "$out"
            ''
          );

      site = import ./hosts/gotenberg/site.nix;
      proxyCfg = cfgOf gotenberg;
      directCfg = cfgOf direct;
      tlsCfg = cfgOf tls;
      proxyFw = fwOf gotenberg;
      directFw = fwOf direct;
      tlsFw = fwOf tls;
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
        proxy-flags = assertText "proxy-flags" gotenberg.config.systemd.services.gotenberg.script (
          scriptPatterns gotenberg
        );
        proxy-firewall = assertText "proxy-firewall" proxyFw.text (
          sourcePatterns proxyCfg
          ++ dportPatterns proxyFw.backend (clientPorts proxyCfg)
          ++ dportPatterns proxyFw.backend [ 22 ]
          ++ site.adminSourceRanges
          ++ [
            "gotenberg-lan"
            "ssh-admin"
          ]
        );
        proxy-firewall-closed = forbidPorts "proxy-firewall-closed" gotenberg (
          lib.optionals (proxyCfg.proxy.enable && !proxyCfg.proxy.tls.enable) (
            lib.optional (proxyCfg.port != 80 && proxyCfg.port != 443) proxyCfg.port ++ lib.optional (proxyCfg.port != 443) 443
          )
        );
        direct-flags = assertText "direct-flags" direct.config.systemd.services.gotenberg.script (
          scriptPatterns direct
        );
        direct-firewall = assertText "direct-firewall" directFw.text (
          sourcePatterns directCfg ++ dportPatterns directFw.backend (clientPorts directCfg)
        );
        direct-firewall-closed = forbidPorts "direct-firewall-closed" direct (
          lib.subtractLists (clientPorts directCfg) [
            80
            443
          ]
        );
        tls-firewall = assertText "tls-firewall" tlsFw.text (
          sourcePatterns tlsCfg ++ dportPatterns tlsFw.backend (clientPorts tlsCfg)
        );
        tls-firewall-closed = forbidPorts "tls-firewall-closed" tls (
          lib.optional (tlsCfg.port != 80 && tlsCfg.port != 443) tlsCfg.port
        );
        # Same closure nixos-rebuild build produces.
        system = gotenberg.config.system.build.toplevel;
      };
    };
}
