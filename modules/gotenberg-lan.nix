{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.gotenberg-lan;
  sourceFilter = import ./source-filter.nix { inherit lib; };

  containerName = "gotenberg";
  # Port inside the container. In proxy mode the host publishes a different
  # loopback port; in direct mode the API binds cfg.port on the host network.
  containerPort = 3000;
  useProxy = cfg.proxy.enable;
  apiPort = if useProxy then containerPort else cfg.port;
  bindIp = if useProxy then "0.0.0.0" else cfg.listenAddress;
  healthUrl =
    if bindIp == "0.0.0.0" then
      "http://127.0.0.1:${toString apiPort}/health"
    else
      "http://${bindIp}:${toString apiPort}/health";

  imageRef =
    if cfg.image.digest == "" then
      "${cfg.image.repository}:${cfg.image.tag}"
    else
      "${cfg.image.repository}:${cfg.image.tag}@${cfg.image.digest}";

  nginxBodySize =
    let
      matched = builtins.match "([0-9]+)([KMGT])B" cfg.bodyLimit;
    in
    if matched == null then
      throw "services.gotenberg-lan.bodyLimit must look like 64MB or 1GB, not ${cfg.bodyLimit}"
    else
      "${lib.elemAt matched 0}${lib.toLower (lib.elemAt matched 1)}";

  exposedPorts =
    if !cfg.openFirewall then
      [ ]
    else if !useProxy then
      [ cfg.port ]
    else if cfg.proxy.tls.enable then
      [
        80
        443
      ]
    else
      [ 80 ];

  # On-box checks of the LAN URL come from this host's own address.
  firewallSources = lib.unique (
    cfg.allowedSourceRanges
    ++ lib.optional (cfg.listenAddress != "0.0.0.0" && cfg.listenAddress != "127.0.0.1") "${cfg.listenAddress}/32"
  );

  fw = sourceFilter {
    backend = config.networking.firewall.backend;
    ports = exposedPorts;
    sources = firewallSources;
    comment = "gotenberg-lan";
  };

  apiFlags = [
    "gotenberg"
    "--api-port=${toString apiPort}"
    "--api-bind-ip=${bindIp}"
    "--api-timeout=${cfg.timeouts.api}"
    "--api-start-timeout=${cfg.timeouts.apiStart}"
    "--api-body-limit=${cfg.bodyLimit}"
    "--gotenberg-graceful-shutdown-duration=${cfg.timeouts.gracefulShutdown}"
    "--log-level=${cfg.log.level}"
    "--log-std-format=${cfg.log.format}"
    "--api-disable-health-check-route-telemetry=true"
  ]
  ++ lib.optional cfg.disableDownloadFrom "--api-disable-download-from=true"
  ++ cfg.extraFlags;

  proxyLocation = {
    proxyPass = "http://127.0.0.1:${toString cfg.port}";
    extraConfig = ''
      proxy_http_version 1.1;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_connect_timeout 10s;
      proxy_read_timeout ${cfg.timeouts.api};
      proxy_send_timeout ${cfg.timeouts.api};
      client_max_body_size ${nginxBodySize};
      client_body_timeout ${cfg.timeouts.api};
      proxy_request_buffering off;
    '';
  };

  ipv4 = "(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])";
  ipv4Cidr = "${ipv4}(/([0-9]|[1-2][0-9]|3[0-2]))?";
in
{
  options.services.gotenberg-lan = {
    enable = lib.mkEnableOption "LAN-only Gotenberg for Factur-X / ZUGFeRD";

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "gotenberg.dueren.de";
      example = "gotenberg.intern.dueren.de";
      description = ''
        Single internal DNS name for this service. The Hyper-V host derives
        `networking.hostName` and `networking.domain` from it.

        `gotenberg.dueren.de` matches an existing `*.dueren.de` certificate.
        `gotenberg.intern.dueren.de` needs its own DNS zone and does not match
        a one-label `*.dueren.de` wildcard. See docs/tls.md for split DNS.
      '';
    };

    listenAddress = lib.mkOption {
      type = lib.types.strMatching ipv4;
      example = "10.0.10.20";
      description = ''
        IPv4 address of the internal interface clients connect to.
        With the reverse proxy this is where nginx listens.
        Without the proxy, Gotenberg binds this address on the host network
        so the NixOS firewall can see the traffic.

        Use `0.0.0.0` only when the address is assigned by DHCP. Published
        container ports on a non-loopback address bypass the NixOS firewall,
        so this module never publishes the API that way.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = ''
        Host port of the Gotenberg API. In direct mode this port is bound on
        `listenAddress`. In proxy mode it is bound on `127.0.0.1` only and
        nginx is the LAN listener.
      '';
    };

    allowedSourceRanges = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching ipv4Cidr);
      example = [
        "10.0.20.0/24"
        "10.0.20.15"
      ];
      description = ''
        IPv4 addresses and CIDR ranges of the IIS servers allowed to call
        Gotenberg. The firewall accepts only these sources. Leave this empty
        only when `openFirewall` is false.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Accept the client port (3000, or 80/443 when the proxy is enabled)
        from `allowedSourceRanges` only. The port is not added to
        `networking.firewall.allowedTCPPorts`, which would open it to every source.
      '';
    };

    backend = lib.mkOption {
      type = lib.types.enum [
        "podman"
        "docker"
      ];
      default = "podman";
      description = "OCI runtime used by virtualisation.oci-containers.";
    };

    image = {
      repository = lib.mkOption {
        type = lib.types.str;
        default = "docker.io/gotenberg/gotenberg";
        description = "Container image repository.";
      };

      tag = lib.mkOption {
        type = lib.types.str;
        default = "8.37.0";
        description = ''
          Image tag. Factur-X (`POST /forms/pdfengines/factur-x`) shipped in
          8.34.0. 8.37.0 is the current stable release and includes that API.
        '';
      };

      digest = lib.mkOption {
        type = lib.types.str;
        default = "sha256:3fdee07e0dcd5005c3db4d81d1600d081fc6fb424da87e409e1c1f9624a249b8";
        description = ''
          Image digest pinned to the linux/amd64 manifest of the tag.
          Set to an empty string to float on the tag.
        '';
      };
    };

    timeouts = {
      api = lib.mkOption {
        type = lib.types.str;
        default = "120s";
        description = ''
          Gotenberg `--api-timeout`. Also used as the nginx proxy read timeout.
          The ASP.NET HttpClient timeout should be a little higher than this.
        '';
      };

      apiStart = lib.mkOption {
        type = lib.types.str;
        default = "60s";
        description = "Gotenberg `--api-start-timeout`.";
      };

      gracefulShutdown = lib.mkOption {
        type = lib.types.str;
        default = "30s";
        description = "Gotenberg `--gotenberg-graceful-shutdown-duration`.";
      };
    };

    bodyLimit = lib.mkOption {
      type = lib.types.str;
      default = "64MB";
      example = "100MB";
      description = ''
        Multipart body limit (`--api-body-limit`) for PDF and Factur-X XML
        uploads. A matching nginx `client_max_body_size` is applied when the
        proxy is enabled.
      '';
    };

    log = {
      level = lib.mkOption {
        type = lib.types.enum [
          "error"
          "warn"
          "info"
          "debug"
        ];
        default = "info";
        description = "Gotenberg `--log-level`. Container stdout goes to the journal.";
      };

      format = lib.mkOption {
        type = lib.types.enum [
          "auto"
          "json"
          "text"
        ];
        default = "json";
        description = "Gotenberg `--log-std-format`.";
      };
    };

    resources = {
      memory = lib.mkOption {
        type = lib.types.str;
        default = "2g";
        description = "Container memory limit (`--memory`). Size the VM above this.";
      };

      cpus = lib.mkOption {
        type = lib.types.str;
        default = "2";
        description = "Container CPU limit (`--cpus`).";
      };

      pidsLimit = lib.mkOption {
        type = lib.types.ints.positive;
        default = 512;
        description = "Container process limit (`--pids-limit`).";
      };

      shmSize = lib.mkOption {
        type = lib.types.str;
        default = "1g";
        description = "Size of /dev/shm. Chromium conversions need more than the runtime default.";
      };
    };

    disableDownloadFrom = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Disable Gotenberg's `downloadFrom` URL fetch. The ERechnung module
        uploads the PDF and XML itself. Leave this on unless a caller must
        pass remote URLs.
      '';
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--chromium-max-queue-size=8" ];
      description = "Extra arguments appended after the generated `gotenberg` flags.";
    };

    proxy = {
      enable = lib.mkEnableOption ''
        nginx in front of Gotenberg. Phase 1 listens on port 80.
        Gotenberg itself listens on 127.0.0.1 only
      '';

      tls = {
        enable = lib.mkEnableOption ''
          Phase 2 HTTPS on port 443. Requires the proxy. Terminate TLS with the
          existing wildcard certificate; Gotenberg stays on loopback HTTP
        '';

        certificate = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/secrets/gotenberg/fullchain.pem";
          description = ''
            Host path of the PEM full chain (leaf plus intermediates).
            This must be a string, not a Nix path, or the certificate is copied
            into the world-readable Nix store. Never commit the file.
          '';
        };

        key = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/secrets/gotenberg/key.pem";
          description = ''
            Host path of the PEM private key. Root-only, mode 0600.
            String, not a Nix path. Never commit the file.
          '';
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.openFirewall -> cfg.allowedSourceRanges != [ ];
        message = ''
          services.gotenberg-lan.allowedSourceRanges is empty.
          Set the IIS subnets, or set openFirewall = false.
        '';
      }
      {
        assertion = config.networking.firewall.backend != "firewalld";
        message = ''
          services.gotenberg-lan source filtering supports the iptables and
          nftables firewall backends, not firewalld.
        '';
      }
      {
        assertion = cfg.proxy.tls.enable -> cfg.proxy.enable;
        message = ''
          services.gotenberg-lan.proxy.tls.enable needs proxy.enable.
          nginx terminates TLS and Gotenberg stays on loopback.
        '';
      }
      {
        assertion = lib.hasInfix "." cfg.fqdn;
        message = "services.gotenberg-lan.fqdn must be a DNS name with a dot, for example gotenberg.dueren.de.";
      }
      {
        assertion = cfg.image.digest == "" || lib.hasPrefix "sha256:" cfg.image.digest;
        message = "services.gotenberg-lan.image.digest must be empty or start with sha256:.";
      }
      {
        assertion =
          cfg.proxy.tls.enable
          -> (lib.hasPrefix "/" cfg.proxy.tls.certificate && lib.hasPrefix "/" cfg.proxy.tls.key);
        message = "TLS certificate and key must be absolute host paths.";
      }
      {
        assertion =
          !(lib.hasPrefix "/nix/store" cfg.proxy.tls.certificate)
          && !(lib.hasPrefix "/nix/store" cfg.proxy.tls.key);
        message = "Refusing a TLS certificate or key inside /nix/store. Point at /var/lib/secrets.";
      }
    ];

    warnings =
      lib.optional (cfg.listenAddress == "0.0.0.0") ''
        services.gotenberg-lan.listenAddress is 0.0.0.0. The firewall still
        limits clients to allowedSourceRanges, but the socket is open on every
        interface. Bind the LAN address when it is static.
      ''
      ++ lib.optional (lib.elem cfg.port config.networking.firewall.allowedTCPPorts) ''
        TCP port ${toString cfg.port} is in networking.firewall.allowedTCPPorts,
        which accepts every source. Remove it and use allowedSourceRanges.
      ''
      ++ lib.optional (
        useProxy && lib.elem 80 config.networking.firewall.allowedTCPPorts
      ) ''
        TCP port 80 is in networking.firewall.allowedTCPPorts. Remove it so only
        the IIS source ranges can reach the proxy.
      ''
      ++ lib.optional (
        cfg.proxy.tls.enable && lib.elem 443 config.networking.firewall.allowedTCPPorts
      ) ''
        TCP port 443 is in networking.firewall.allowedTCPPorts. Remove it so only
        the IIS source ranges can reach HTTPS.
      '';

    environment.systemPackages = [ pkgs.curl ];

    networking.firewall.extraCommands = lib.mkIf (cfg.openFirewall && fw.extraCommands != "") fw.extraCommands;
    networking.firewall.extraInputRules = lib.mkIf (cfg.openFirewall && fw.extraInputRules != "") fw.extraInputRules;

    virtualisation.oci-containers.backend = cfg.backend;
    virtualisation.oci-containers.containers.${containerName} = {
      image = imageRef;
      serviceName = containerName;
      autoStart = true;
      log-driver = "journald";
      cmd = apiFlags;
      ports = lib.optionals useProxy [ "127.0.0.1:${toString cfg.port}:${toString containerPort}" ];
      networks = lib.optionals (!useProxy) [ "host" ];
      extraOptions = [
        "--health-cmd=curl --fail --silent --show-error ${healthUrl}"
        "--health-interval=30s"
        "--health-timeout=5s"
        "--health-retries=3"
        "--health-start-period=40s"
        "--shm-size=${cfg.resources.shmSize}"
        "--memory=${cfg.resources.memory}"
        "--cpus=${cfg.resources.cpus}"
        "--pids-limit=${toString cfg.resources.pidsLimit}"
      ]
      ++ lib.optional (cfg.backend == "podman") "--health-on-failure=restart";
      podman = lib.mkIf (cfg.backend == "podman") {
        sdnotify = "healthy";
      };
    };

    systemd.services.${containerName} = {
      serviceConfig = {
        Restart = lib.mkForce "always";
        RestartSec = "5s";
      };
    };

    systemd.tmpfiles.rules = lib.mkIf cfg.proxy.tls.enable [
      "d /var/lib/secrets 0700 root root -"
      "d /var/lib/secrets/gotenberg 0700 root root -"
    ];

    services.nginx = lib.mkIf useProxy {
      enable = true;
      recommendedProxySettings = lib.mkDefault true;
      recommendedTlsSettings = lib.mkDefault cfg.proxy.tls.enable;
      sslProtocols = lib.mkIf cfg.proxy.tls.enable (lib.mkDefault "TLSv1.2 TLSv1.3");
      clientMaxBodySize = lib.mkDefault nginxBodySize;
      proxyTimeout = lib.mkDefault cfg.timeouts.api;

      virtualHosts = lib.mkMerge [
        (lib.mkIf (!cfg.proxy.tls.enable) {
          ${cfg.fqdn} = {
            serverName = cfg.fqdn;
            http2 = false;
            listen = [
              {
                addr = cfg.listenAddress;
                port = 80;
              }
            ];
            extraConfig = ''
              server_tokens off;
              client_max_body_size ${nginxBodySize};
            '';
            locations."/health" = proxyLocation // {
              extraConfig = proxyLocation.extraConfig + ''
                access_log off;
              '';
            };
            locations."/" = proxyLocation;
          };
        })
        (lib.mkIf cfg.proxy.tls.enable {
          "${cfg.fqdn}-http" = {
            serverName = cfg.fqdn;
            http2 = false;
            listen = [
              {
                addr = cfg.listenAddress;
                port = 80;
              }
            ];
            extraConfig = "server_tokens off;";
            locations."/" = {
              return = "308 https://${cfg.fqdn}$request_uri";
            };
          };
          ${cfg.fqdn} = {
            serverName = cfg.fqdn;
            http2 = true;
            listen = [
              {
                addr = cfg.listenAddress;
                port = 443;
                ssl = true;
              }
            ];
            sslCertificate = cfg.proxy.tls.certificate;
            sslCertificateKey = cfg.proxy.tls.key;
            extraConfig = ''
              server_tokens off;
              ssl_protocols TLSv1.2 TLSv1.3;
              ssl_session_tickets off;
              client_max_body_size ${nginxBodySize};
            '';
            locations."/health" = proxyLocation // {
              extraConfig = proxyLocation.extraConfig + ''
                access_log off;
              '';
            };
            locations."/" = proxyLocation;
          };
        })
      ];
    };
  };
}
