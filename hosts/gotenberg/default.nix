{
  config,
  lib,
  pkgs,
  ...
}:
let
  site = import ./site.nix;
  sourceFilter = import ../../modules/source-filter.nix { inherit lib; };

  nameParts = lib.splitString "." site.fqdn;
  listenAddress =
    if site.listenAddress != null then
      site.listenAddress
    else if site.useStaticAddress then
      site.address
    else
      "0.0.0.0";

  sshFw = sourceFilter {
    backend = config.networking.firewall.backend;
    ports = [ 22 ];
    sources = site.adminSourceRanges;
    comment = "ssh-admin";
  };

  hashedPassword = if site.initialHashedPassword == null then "!" else site.initialHashedPassword;
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/gotenberg-lan.nix
  ];

  warnings = lib.optional (lib.any (key: lib.hasInfix "REPLACE_ME" key) site.adminAuthorizedKeys) ''
    hosts/gotenberg/site.nix still has the placeholder SSH key (REPLACE_ME).
    Replace adminAuthorizedKeys before installing, or the only login will fail.
  '';

  nixpkgs.hostPlatform = "x86_64-linux";

  # First installed release. Do not change this during later upgrades.
  system.stateVersion = "26.05";

  networking.hostName = lib.head nameParts;
  networking.domain = lib.concatStringsSep "." (lib.tail nameParts);
  networking.usePredictableInterfaceNames = false;
  time.timeZone = site.timeZone;
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = site.consoleKeyMap;

  # hv_utils also offers Hyper-V time sync. timesyncd is the clock of record;
  # disable the Hyper-V time integration service if the clock steps.
  services.timesyncd.enable = true;

  # Loads hv_vmbus, hv_storvsc, hv_netvsc, hv_utils and hv_balloon, and starts
  # the Hyper-V guest daemons (KVP, VSS, file copy) used by production checkpoints.
  virtualisation.hypervGuest.enable = true;
  boot.initrd.kernelModules = [
    "hv_vmbus"
    "hv_storvsc"
    "hv_netvsc"
    "hv_utils"
    "hv_balloon"
  ];

  networking.useDHCP = false;
  networking.interfaces.${site.interface} =
    if site.useStaticAddress then
      {
        useDHCP = false;
        ipv4.addresses = [
          {
            address = site.address;
            prefixLength = site.prefixLength;
          }
        ];
      }
    else
      {
        useDHCP = true;
      };
  networking.defaultGateway = lib.mkIf site.useStaticAddress {
    address = site.gateway;
    interface = site.interface;
  };
  networking.nameservers = site.nameservers;
  networking.hosts = lib.mkIf site.useStaticAddress {
    ${site.address} = [ site.fqdn ];
  };

  services.gotenberg-lan = {
    enable = true;
    fqdn = site.fqdn;
    inherit listenAddress;
    port = site.apiPort;
    allowedSourceRanges = site.iisSourceRanges;
    proxy.enable = site.httpProxy;
    proxy.tls.enable = site.tls.enable;
  };

  users.mutableUsers = false;
  users.users.${site.adminUser} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = hashedPassword;
    openssh.authorizedKeys.keys = site.adminAuthorizedKeys;
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ site.adminUser ];
    };
  };

  networking.firewall = {
    enable = true;
    extraCommands = lib.mkIf (sshFw.extraCommands != "") sshFw.extraCommands;
    extraInputRules = lib.mkIf (sshFw.extraInputRules != "") sshFw.extraInputRules;
  };

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    # nix.gc does not touch /var/lib/containers. Drop unused images older than
    # the 14 day generation window; the running image stays because it is in use.
    autoPrune = {
      enable = true;
      dates = "Sun 05:40";
      flags = [
        "--all"
        "--filter"
        "until=336h"
      ];
    };
  };

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
  };

  nix.gc = {
    automatic = true;
    dates = "Sun 05:30";
    options = "--delete-older-than 14d";
  };

  # Rebuilds /etc/nixos, which is a checkout of this flake, and moves the
  # nixpkgs input along nixos-26.05. Host config changes still come from git.
  system.autoUpgrade = {
    enable = true;
    flake = "/etc/nixos#gotenberg";
    flags = [
      "--update-input"
      "nixpkgs"
      "--commit-lock-file"
    ];
    dates = "02:15";
    randomizedDelaySec = "30min";
    allowReboot = true;
    rebootWindow = {
      lower = "01:00";
      upper = "05:00";
    };
    operation = "switch";
  };

  programs.git = {
    enable = true;
    config = {
      user.name = "NixOS autoUpgrade";
      user.email = "root@${site.fqdn}";
      safe.directory = "/etc/nixos";
      init.defaultBranch = "main";
    };
  };

  environment.systemPackages = with pkgs; [
    git
    curl
    openssl
    jq
    iptables
  ];

  services.journald.extraConfig = ''
    SystemMaxUse=500M
    MaxRetentionSec=2week
  '';
}
