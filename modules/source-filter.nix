# Build firewall rules that accept TCP ports only from the given IPv4
# sources. Published container ports bypass this firewall, so callers must
# not publish those ports on a non-loopback address.
{ lib }:
{
  backend,
  ports,
  sources,
  comment,
}:
let
  portList = lib.concatMapStringsSep ", " toString ports;
  sourceList = lib.concatStringsSep ", " sources;
  nftRules = ''
    ip saddr { ${sourceList} } tcp dport { ${portList} } accept comment "${comment}"
  '';
  iptablesRules = lib.concatMapStrings (
    port:
    lib.concatMapStrings (src: ''
      iptables -A nixos-fw -p tcp -s ${src} --dport ${toString port} -j nixos-fw-accept -m comment --comment ${comment}
    '') sources
  ) ports;
in
if backend == "nftables" then
  {
    extraInputRules = nftRules;
    extraCommands = "";
  }
else if backend == "iptables" then
  {
    extraInputRules = "";
    extraCommands = iptablesRules;
  }
else
  {
    extraInputRules = "";
    extraCommands = "";
  }
