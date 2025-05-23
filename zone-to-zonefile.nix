{ lib, ... }:

{ timestamp, domain, zone, ... }:

with lib;
let
  removeBlankLines = str:
    concatStringsSep "\n\n" (filter isString (builtins.split ''


      +'' str));

  joinLines = concatStringsSep "\n";

  nSpaces = n: concatStrings (genList (_: " ") n);

  padToLength = strlen: str:
    let spaces = nSpaces (strlen - (stringLength str));
    in str + spaces;

  maxInt = foldr (a: b: if (a < b) then b else a) 0;

  recordMatcher = builtins.match "^([^;].*) IN ([A-Z][A-Z0-9]*) (.+)$";

  isRecord = str: (recordMatcher str) != null;

  makeZoneFormatter = zonedata:
    let
      lines = splitString "\n" zonedata;
      records = filter isRecord lines;
      splitRecords = map recordMatcher records;
      indexStrlen = i: record: stringLength (elemAt record i);
      recordIndexMaxlen = i: maxInt (map (indexStrlen i) splitRecords);
    in recordFormatter (recordIndexMaxlen 0) (recordIndexMaxlen 1);

  recordFormatter = nameMax: typeMax:
    let
      namePadder = padToLength nameMax;
      typePadder = padToLength typeMax;
    in recordLine:
    let recordParts = recordMatcher recordLine;
    in if (recordParts == null) then
      recordLine
    else
      (let
        name = elemAt recordParts 0;
        type = elemAt recordParts 1;
        data = elemAt recordParts 2;
      in "${namePadder name} IN ${typePadder type} ${data}");

  formatZone = zonedata:
    let
      formatter = makeZoneFormatter zonedata;
      lines = splitString "\n" zonedata;
    in concatStringsSep "\n" (map formatter lines);

  isNotNull = o: o != null;

  hostToFqdn = host:
    let hostChars = "[a-zA-Z0-9_-]";
    in if isNotNull (builtins.match "^${hostChars}+$" host) then
      "${host}.${domain}."
    else if isNotNull
    (builtins.match "(${hostChars}+\\.)+${hostChars}+\\.$" host) then
      host
    else if isNotNull
    (builtins.match "(${hostChars}+\\.)+${hostChars}+$" host) then
      "${host}."
    else
      abort "unrecognized hostname: ${host}";

  makeSrvRecords = protocol: service: records:
    joinLines (map (record:
      let fqdn = hostToFqdn record.host;
      in "_${service}._${protocol} IN SRV ${toString record.priority} ${
        toString record.weight
      } ${toString record.port} ${fqdn}") records);

  makeSrvProtocolRecords = protocol: serviceRecords:
    joinLines (mapAttrsToList (makeSrvRecords protocol) serviceRecords);

  makeMetricRecords = metricType: records:
    joinLines (map (record:
      "${metricType}._metrics._tcp IN SRV ${toString record.priority} ${
        toString record.weight
      } ${toString record.port} ${hostToFqdn record.host}") records);

  makeHostRecords = hostname:
    { ipv4-address, ipv6-address, sshfp-records, description, ... }:
    let
      sshfpRecords = map (sshfp: "${hostname} IN SSHFP ${sshfp}") sshfp-records;
      aRecord =
        optional (ipv4-address != null) "${hostname} IN A ${ipv4-address}";
      aaaaRecord =
        optional (ipv6-address != null) "${hostname} IN AAAA ${ipv6-address}";
      descriptionRecord =
        optional (description != null) ''${hostname} IN TXT "${description}"'';
    in joinLines (aRecord ++ aaaaRecord ++ sshfpRecords ++ descriptionRecord);

  cnameRecord = alias: host: "${alias} IN CNAME ${host}";

  dmarcRecord = dmarcEmail:
    optionalString (dmarcEmail != null) ''
      _dmarc IN TXT "v=DMARC1;p=quarantine;sp=quarantine;rua=mailto:${dmarcEmail};"'';

  mxRecords = map (mx: "@ IN MX 10 ${hostToFqdn mx}");

  nsRecords = map (ns-host: "@ IN NS ${ns-host}");

  flatmapAttrsToList = f: attrs:
    foldr (a: b: a ++ b) [ ] (mapAttrsToList f attrs);

  domainRecords = domain: zone:
    let
      defaultHostRecords = optionalString (zone.default-host != null)
        (makeHostRecords "@" zone.default-host);

      kerberosRecord = optionalString (zone.gssapi-realm != null)
        ''_kerberos IN TXT "${zone.gssapi-realm}"'';

      subdomainRecords = joinLines (mapAttrsToList
        (subdom: subdomCfg: domainRecords "${subdom}.${domain}" subdomCfg)
        zone.subdomains);

    in ''
      $ORIGIN ${domain}.
      $TTL ${zone.default-ttl}

      ${defaultHostRecords}

      ${joinLines (mxRecords zone.mx)}

      ${dmarcRecord zone.dmarc-report-address}

      ${kerberosRecord}

      ${joinLines (nsRecords zone.nameservers)}

      ${joinLines (mapAttrsToList makeSrvProtocolRecords zone.srv-records)}

      ${joinLines (mapAttrsToList makeMetricRecords zone.metric-records)}

      ${joinLines (mapAttrsToList cnameRecord zone.aliases)}

      ${joinLines zone.verbatim-dns-records}

      $TTL ${zone.host-record-ttl}

      ${joinLines (mapAttrsToList makeHostRecords zone.hosts)}

      ${subdomainRecords}
    '';

in removeBlankLines (formatZone ''
  $ORIGIN ${domain}.
  $TTL ${zone.default-ttl}

  @ IN SOA ns1.${domain}. hostmaster.${domain}. (
      ${toString timestamp}
      30m
      2m
      3w
      5m)

  ${domainRecords domain zone}
'')
