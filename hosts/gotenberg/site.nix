# Site values for the Gotenberg VM.
#
# This is the only file that should contain host-specific data:
# the DNS name, addresses, the IIS subnet, the admin SSH key, and the
# HTTP / HTTPS phase switch. Everything else reads from here.
#
# Before the first install:
#   1. Replace the placeholder public key in adminAuthorizedKeys.
#   2. Replace the addresses below with the LAN plan.
#   3. Create the internal DNS A record for `fqdn`. Do not publish it publicly.
#
# Phase 1 (default): httpProxy = true, tls.enable = false
#   Base URL: http://<fqdn>          (nginx on port 80)
#   Direct:   set httpProxy = false  -> http://<fqdn>:3000
#
# Phase 2: place the certificate (docs/tls.md), then set tls.enable = true
#   and keep httpProxy = true.
#   Base URL: https://<fqdn>
#
# DNS name alternatives and split DNS are documented in docs/hyperv-setup.md
# and docs/tls.md. A one-label wildcard *.dueren.de matches
# gotenberg.dueren.de and does not match gotenberg.intern.dueren.de.
{
  fqdn = "gotenberg.dueren.de";

  # Hyper-V presents the NIC as eth0 because predictable names are disabled.
  interface = "eth0";
  useStaticAddress = true;
  address = "10.0.10.20"; # CHANGE_ME
  prefixLength = 24;
  gateway = "10.0.10.1"; # CHANGE_ME
  nameservers = [ "10.0.10.1" ]; # CHANGE_ME internal DNS

  # null binds `address`. Set "0.0.0.0" only together with useStaticAddress = false.
  listenAddress = null;

  # IIS servers that call Gotenberg. Firewall source list for ports 80/443 or 3000.
  iisSourceRanges = [ "10.0.20.0/24" ]; # CHANGE_ME

  # Workstations allowed to SSH. Not opened to the whole LAN.
  adminSourceRanges = [ "10.0.10.0/24" ]; # CHANGE_ME

  adminUser = "admin";
  # Public key only. Password authentication over SSH stays off.
  # Generate with: ssh-keygen -t ed25519 -C "gotenberg-admin"
  adminAuthorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMbEovsHNoAxVVUlTlAe9ol+bjX2+l3yMy0AQkTicrDs REPLACE_ME"
  ];

  # SHA-512 hash from `mkpasswd -m sha-512` for the Hyper-V console.
  # null locks the password. SSH key login still works. SSH never accepts the password.
  # Do not commit a real hash to a shared remote.
  initialHashedPassword = null;

  timeZone = "Europe/Berlin";
  consoleKeyMap = "de";

  apiPort = 3000;

  # Phase 1. false serves Gotenberg directly on apiPort.
  httpProxy = true;

  # Phase 2. Certificate files must already be on disk. See docs/tls.md.
  tls.enable = false;
}
