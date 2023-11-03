{ pkgs, ... }:

{ domain, network, nameservers, ipHostMap, serial, zoneTTL ? 10800
, refresh ? 3600, retry ? 1800, expire ? 604800, minimum ? 3600 }:

with pkgs.lib;
let
  inherit (pkgs.lib.ip) networkMinIp networkMaxButOneIp ipv4OnNetwork;

  range = base: top:
    assert base < top;
    let
      rangeFun = base: top:
        if base == top then [ ] else [ base ] ++ (rangeFun (base + 1) top);
    in rangeFun base top;

  getNetworkHosts = network: filterAttrs (ip: _: ipv4OnNetwork ip network);

  getLastIpComponent = ip: head (reverseList (splitString "." ip));

  getNetworkZoneName = network:
    let
      netElems = splitString "/" network;
      netIp = elemAt netElems 0;
      netMask = elemAt netElems 1;
      reversedNetIp =
        concatStringsSep "." (tail (reverseList (splitString "." netIp)));
    in if netMask == "24" then
      "${reversedNetIp}.in-addr.arpa."
    else
      "${getLastIpComponent netIp}-${netMask}.${reversedNetIp}.in-addr.arpa.";

  generateReverseZoneEntries = network: domain: ipHostMap:
    let
      networkHostsByComponent =
        mapAttrs' (ip: hostname: nameValuePair (getLastIpComponent ip) hostname)
        (getNetworkHosts network ipHostMap);
      ptrEntry = ip: hostname: "#{ip} IN PTR ${hostname}.";
      getHostname = n:
        if hasAttr n networkHostsByComponent then
          networkHostsByComponent."${n}"
        else
          "unassigned-${n}.${domain}";
      minIp = toInt (getLastIpComponent (networkMinIp network));
      maxIp = toInt (getLastIpComponent (networkMaxButOneIp network));
    in map (n: ptrEntry n (getHostname (toString n))) (range minIp maxIp);

  nameserverEntries = map (nameserver: "@ IN NS ${nameserver}.") nameservers;

in nameValuePair "${getNetworkZoneName network}" ''
  $ORIGIN ${getNetworkZoneName network}
  $TTL ${toString zoneTTL}
  @ IN SOA ${head nameservers}. hostmaster.${domain}. (
    ${serial}
    ${toString refresh}
    ${toString retry}
    ${toString expire}
    ${toString minimum}
  )
  ${concatStringsSep "\n" nameserverEntries}
  ${concatStringsSep "\n" (generateReverseZoneEntries network domain ipHostMap)}
''
