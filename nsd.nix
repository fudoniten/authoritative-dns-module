{ config, pkgs, lib, ... }:

### NOTE: This is a copy of the upstream version, which allows for overriding
## the state directory AND specifying zone-level key-signing keys (instead of
## generating them)

with lib;
let
  cfg = config.services.fudo-nsd;

  username = cfg.user;
  stateDir = cfg.stateDirectory;
  pidFile = "${stateDir}/run/nsd.pid";

  # build nsd with the options needed for the given config
  nsdPkg = pkgs.nsd.override {
    bind8Stats = cfg.bind8Stats;
    ipv6 = cfg.ipv6;
    ratelimit = cfg.ratelimit.enable;
    rootServer = cfg.rootServer;
    zoneStats = length (collect (x: (x.zoneStats or null) != null) cfg.zones)
      > 0;
  };

  maybeConfig = prefix: x: if x == null then "" else ''${prefix} "${x}"'';

  maybeIntConfig = prefix: x:
    if x == null then "" else "${prefix} ${toString x}";

  yesOrNo = b: if b then "yes" else "no";
  maybeToString = prefix: x:
    if x == null then "" else "${prefix} ${toString x}";
  forEach = pre: l: concatMapStrings (x: pre + x + "\n") l;

  mkZoneFileName = name: if name == "." then "root" else name;

  # replaces include: directives for keys with fake keys for nsd-checkconf
  injectFakeKeys = keys:
    concatStrings (mapAttrsToList (keyName: keyOptions: ''
      fakeKey="$(${pkgs.bind}/bin/tsig-keygen -a ${
        escapeShellArgs [ keyOptions.algorithm keyName ]
      } | grep -oP "\s*secret \"\K.*(?=\";)")"
      sed "s@^\s*include:\s*\"${stateDir}/private/${keyName}\"\$@secret: $fakeKey@" -i $out/nsd.conf
    '') keys);

  nsdEnv = pkgs.buildEnv {
    name = "nsd-env";

    paths = [ configFile ]
      ++ mapAttrsToList (name: zone: writeZoneData name zone) zoneConfigs;

    postBuild = optionalString cfg.checkZonefiles ''
      echo "checking zone files"
      cd $out/zones

      for zoneFile in *; do
        echo "|- checking zone '$out/zones/$zoneFile'"
        ${nsdPkg}/sbin/nsd-checkzone "$zoneFile" "$zoneFile" || {
          if grep -q \\\\\\$ "$zoneFile"; then
            echo zone "$zoneFile" contains escaped dollar signs \\\$
            echo Escaping them is not needed any more. Please make sure \
                 to unescape them where they prefix a variable name.
          fi

          exit 1
        }
      done
    '' + ''
      echo "checking configuration file"
      # Save original config file including key references...
      cp $out/nsd.conf{,.orig}
      # ...inject mock keys into config
      ${injectFakeKeys cfg.keys}
      # ...do the checkconf
      ${nsdPkg}/sbin/nsd-checkconf $out/nsd.conf
      # ... and restore original config file.
      mv $out/nsd.conf{.orig,}
    '';
  };

  writeZoneData = name:
    { data, includes, ... }:
    pkgs.writeTextFile {
      name = "nsd-zone-${mkZoneFileName name}";
      text = let
        includeClauses =
          map (file: "$INCLUDE ./zones/includes-${name}/${baseNameOf file}")
          includes;
      in data + ''
        $ORIGIN ${name}
        ${concatStringsSep "\n" includeClauses}
      '';
      destination = "/zones/${mkZoneFileName name}";
    };

  # options are ordered alphanumerically by the nixos option name
  configFile = pkgs.writeTextDir "nsd.conf" ''
    server:
      chroot:   "${stateDir}"
      username: "${username}"

      # The directory for zonefile: files. The daemon chdirs here.
      zonesdir: "${stateDir}"

      # the list of dynamically added zones.
      pidfile:      "${pidFile}"
      xfrdfile:     "${stateDir}/var/xfrd.state"
      xfrdir:       "${stateDir}/tmp"
      zonelistfile: "${stateDir}/var/zone.list"

      # interfaces
    ${forEach "  ip-address: " cfg.interfaces}

      ip-freebind:         ${yesOrNo cfg.ipFreebind}
      hide-version:        ${yesOrNo cfg.hideVersion}
      identity:            "${cfg.identity}"
      ip-transparent:      ${yesOrNo cfg.ipTransparent}
      do-ip4:              ${yesOrNo cfg.ipv4}
      ipv4-edns-size:      ${toString cfg.ipv4EDNSSize}
      do-ip6:              ${yesOrNo cfg.ipv6}
      ipv6-edns-size:      ${toString cfg.ipv6EDNSSize}
      log-time-ascii:      ${yesOrNo cfg.logTimeAscii}
      ${maybeConfig "nsid: " cfg.nsid}
      port:                ${toString cfg.port}
      reuseport:           ${yesOrNo cfg.reuseport}
      round-robin:         ${yesOrNo cfg.roundRobin}
      server-count:        ${toString cfg.serverCount}
      ${maybeToString "statistics: " cfg.statistics}
      tcp-count:           ${toString cfg.tcpCount}
      tcp-query-count:     ${toString cfg.tcpQueryCount}
      tcp-timeout:         ${toString cfg.tcpTimeout}
      verbosity:           ${toString cfg.verbosity}
      ${maybeConfig "version: " cfg.version}
      xfrd-reload-timeout: ${toString cfg.xfrdReloadTimeout}
      zonefiles-check:     ${yesOrNo cfg.zonefilesCheck}
      zonefiles-write:     ${toString cfg.zonefilesWrite}

      ${maybeConfig "rrl-ipv4-prefix-length: " cfg.ratelimit.ipv4PrefixLength}
      ${maybeConfig "rrl-ipv6-prefix-length: " cfg.ratelimit.ipv6PrefixLength}
      rrl-ratelimit:           ${toString cfg.ratelimit.ratelimit}
      ${maybeConfig "rrl-slip: " cfg.ratelimit.slip}
      rrl-size:                ${toString cfg.ratelimit.size}
      rrl-whitelist-ratelimit: ${toString cfg.ratelimit.whitelistRatelimit}

    ${keyConfigFile}

    remote-control:
      control-enable:    ${yesOrNo cfg.remoteControl.enable}
      control-key-file:  "${cfg.remoteControl.controlKeyFile}"
      control-cert-file: "${cfg.remoteControl.controlCertFile}"
    ${forEach "  control-interface: " cfg.remoteControl.interfaces}
      control-port:      ${toString cfg.remoteControl.port}
      server-key-file:   "${cfg.remoteControl.serverKeyFile}"
      server-cert-file:  "${cfg.remoteControl.serverCertFile}"

    ${concatStrings (mapAttrsToList zoneConfigFile zoneConfigs)}

    ${cfg.extraConfig}
  '';

  keyConfigFile = concatStrings (mapAttrsToList (keyName: keyOptions: ''
    key:
      name:      "${keyName}"
      algorithm: "${keyOptions.algorithm}"
      include:   "${stateDir}/private/${keyName}"
  '') cfg.keys);

  copyKeys = concatStrings (mapAttrsToList (keyName: keyOptions: ''
    secret=$(cat "${keyOptions.keyFile}")
    dest="${stateDir}/private/${keyName}"
    install -m 0400 -o "${username}" -g "${username}" <(echo "  secret: \"$secret\"") "$dest"
  '') cfg.keys);

  # options are ordered alphanumerically by the nixos option name
  zoneConfigFile = name: zone: ''
    zone:
      name:         "${name}"
      zonefile:     "${stateDir}/zones/${mkZoneFileName name}"
      ${maybeConfig "outgoing-interface: " zone.outgoingInterface}
    ${forEach "  rrl-whitelist: " zone.rrlWhitelist}
      ${maybeConfig "zonestats: " zone.zoneStats}

      ${maybeToString "max-refresh-time: " zone.maxRefreshSecs}
      ${maybeToString "min-refresh-time: " zone.minRefreshSecs}
      ${maybeToString "max-retry-time:   " zone.maxRetrySecs}
      ${maybeToString "min-retry-time:   " zone.minRetrySecs}

      allow-axfr-fallback: ${yesOrNo zone.allowAXFRFallback}
      multi-master-check: ${yesOrNo zone.multiMasterCheck}
    ${forEach "  allow-notify: " zone.allowNotify}
    ${forEach "  request-xfr: " zone.requestXFR}

    ${forEach "  notify: " zone.notify}
    ${maybeIntConfig "notify-retry: " zone.notifyRetry}
    ${forEach "  provide-xfr: " zone.provideXFR}
  '';

  zoneConfigs = zoneConfigs' { } "" { children = cfg.zones; };

  zoneConfigs' = parent: name: zone:
    if !(zone ? children) || zone.children == null || zone.children == { }
    # leaf -> actual zone
    then
      listToAttrs [
        (nameValuePair name (parent // zone))
      ]

      # fork -> pattern
    else
      zipAttrsWith (name: head) (mapAttrsToList (name: child:
        zoneConfigs' (parent // zone // { children = { }; }) name child)
        zone.children);

  # options are ordered alphanumerically
  zoneOptions = types.submodule {
    options = {

      includes = mkOption {
        type = types.listOf types.str;
        description =
          "List of files to include at the end of the zonefile. NOTE: incompatible with DNSSEC and zonefile checking.";
        default = [ ];
      };

      allowAXFRFallback = mkOption {
        type = types.bool;
        default = true;
        description = ''
          If NSD as secondary server should be allowed to AXFR if the primary
          server does not allow IXFR.
        '';
      };

      allowNotify = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "192.0.2.0/24 NOKEY"
          "10.0.0.1-10.0.0.5 my_tsig_key_name"
          "10.0.3.4&255.255.0.0 BLOCKED"
        ];
        description = ''
          Listed primary servers are allowed to notify this secondary server.

          Format: `<ip> <key-name | NOKEY | BLOCKED>`

          `<ip>` either a plain IPv4/IPv6 address or range.
          Valid patters for ranges:
          * `10.0.0.0/24`: via subnet size
          * `10.0.0.0&255.255.255.0`: via subnet mask
          * `10.0.0.1-10.0.0.254`: via range

          A optional port number could be added with a '@':
          * `2001:1234::1@1234`

          `<key-name | NOKEY | BLOCKED>`
          * `<key-name>` will use the specified TSIG key
          * `NOKEY` no TSIG signature is required
          * `BLOCKED`notifies from non-listed or blocked IPs will be ignored
        '';
      };

      children = mkOption {
        # TODO: This relies on the fact that `types.anything` doesn't set any
        # values of its own to any defaults, because in the above zoneConfigs',
        # values from children override ones from parents, but only if the
        # attributes are defined. Because of this, we can't replace the element
        # type here with `zoneConfigs`, since that would set all the attributes
        # to default values, breaking the parent inheriting function.
        type = types.attrsOf types.anything;
        default = { };
        description = ''
          Children zones inherit all options of their parents. Attributes
          defined in a child will overwrite the ones of its parent. Only
          leaf zones will be actually served. This way it's possible to
          define maybe zones which share most attributes without
          duplicating everything. This mechanism replaces nsd's patterns
          in a save and functional way.
        '';
      };

      data = mkOption {
        type = types.lines;
        default = "";
        description = ''
          The actual zone data. This is the content of your zone file.
          Use imports or pkgs.lib.readFile if you don't want this data in your config file.
        '';
      };

      dnssec = mkEnableOption "DNSSEC";

      ksk = {
        keyFile = mkOption {
          type = types.nullOr types.str;
          description =
            "Location of the zone key-signing key file on the local host.";
          default = null;
        };
      };

      maxRefreshSecs = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          Limit refresh time for secondary zones. This is the timer which
          checks to see if the zone has to be refetched when it expires.
          Normally the value from the SOA record is used, but this  option
          restricts that value.
        '';
      };

      minRefreshSecs = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          Limit refresh time for secondary zones.
        '';
      };

      maxRetrySecs = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          Limit retry time for secondary zones. This is the timeout after
          a failed fetch attempt for the zone. Normally the value from
          the SOA record is used, but this option restricts that value.
        '';
      };

      minRetrySecs = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          Limit retry time for secondary zones.
        '';
      };

      multiMasterCheck = mkOption {
        type = types.bool;
        default = false;
        description = ''
          If enabled, checks all masters for the last zone version.
          It uses the higher version from all configured masters.
          Useful if you have multiple masters that have different version numbers served.
        '';
      };

      notify = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "10.0.0.1@3721 my_key" "::5 NOKEY" ];
        description = ''
          This primary server will notify all given secondary servers about
          zone changes.

          Format: `<ip> <key-name | NOKEY>`

          `<ip>` a plain IPv4/IPv6 address with on optional port number (ip@port)

          `<key-name | NOKEY>`
          - `<key-name>` sign notifies with the specified key
          - `NOKEY` don't sign notifies
        '';
      };

      notifyRetry = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          Specifies the number of retries for failed notifies. Set this along with notify.
        '';
      };

      outgoingInterface = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "2000::1@1234";
        description = ''
          This address will be used for zone-transfer requests if configured
          as a secondary server or notifications in case of a primary server.
          Supply either a plain IPv4 or IPv6 address with an optional port
          number (ip@port).
        '';
      };

      provideXFR = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "192.0.2.0/24 NOKEY" "192.0.2.0/24 my_tsig_key_name" ];
        description = ''
          Allow these IPs and TSIG to transfer zones, addr TSIG|NOKEY|BLOCKED
          address range 192.0.2.0/24, 1.2.3.4&255.255.0.0, 3.0.2.20-3.0.2.40
        '';
      };

      requestXFR = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Format: `[AXFR|UDP] <ip-address> <key-name | NOKEY>`
        '';
      };

      rrlWhitelist = mkOption {
        type = with types;
          listOf (enum [
            "nxdomain"
            "error"
            "referral"
            "any"
            "rrsig"
            "wildcard"
            "nodata"
            "dnskey"
            "positive"
            "all"
          ]);
        default = [ ];
        description = ''
          Whitelists the given rrl-types.
        '';
      };

      zoneStats = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "%s";
        description = ''
          When set to something distinct to null NSD is able to collect
          statistics per zone. All statistics of this zone(s) will be added
          to the group specified by this given name. Use "%s" to use the zones
          name as the group. The groups are output from nsd-control stats
          and stats_noreset.
        '';
      };
    };
  };

  dnssecZones =
    (filterAttrs (n: v: if v ? dnssec then v.dnssec else false) zoneConfigs);

  dnssec = dnssecZones != { };

  rotateZoneKeys = zone:
    let zoneDir = "${stateDir}/dnssec/${zone}";
    in ''
      mkdir -p ${zoneDir}
      chown ${username}:${username} ${zoneDir}
      chmod 0600 ${zoneDir}
      ${pkgs.nsdRotateKeys}/bin/nsd-rotate-keys \
        --key-directory=${zoneDir} \
        --validity-period=30 \
        --period-overlap=10 \
        --metadata=${zoneDir}/metadata.json \
        --verbose \
        ${zone}
    '';

  signZone = name: zone: ''
    ${pkgs.nsdSignZone}/bin/nsd-sign-zone \
      --verbose \
      --domain=${name} \
      --ksk-file=${zone.ksk.keyFile} \
      --zsk-metadata=${stateDir}/dnssec/${name}/metadata.json \
      ${stateDir}/zones/${name}
    ${nsdPkg}/sbin/nsd-checkzone \
      ${name} \
      ${stateDir}/zones/${name}.signed &&
    mv -v ${stateDir}/zones/${name}.signed ${stateDir}/zones/${name}
  '';

  # Rotates DNSSEC keys as needed, then (re-)signs every DNSSEC-enabled
  # zone. Run this both in nsd.service's preStart -- so nsd never starts
  # up serving unsigned zones -- and periodically from nsd-dnssec, which
  # SIGHUPs nsd to reload once rotation/signing is done.
  rotateAndSignZones = optionalString dnssec ''
    mkdir -p ${stateDir}/dnssec
    chown ${username}:${username} ${stateDir}/dnssec
    chmod 0600 ${stateDir}/dnssec

    ${concatStringsSep "\n" (map rotateZoneKeys (attrNames dnssecZones))}

    ${concatStringsSep "\n" (mapAttrsToList signZone dnssecZones)}
  '';
in {
  options.services.fudo-nsd = {

    enable = mkEnableOption "NSD authoritative DNS server";

    user = mkOption {
      type = types.str;
      description = "User as which to run the NSD server.";
      default = "nsd";
    };

    checkZonefiles = mkOption {
      type = types.bool;
      description = ''
        Perform nsd-checkzone on zonefiles before deploying.

        Doesn't work with includes that don't exist at build time, so need the
        ability to disable.

        Note: distinct from zonefilesCheck!
      '';
      default = true;
    };

    stateDirectory = mkOption {
      type = types.str;
      description = "Location at which to store NSD state.";
      default = "/var/lib/nsd";
    };

    bind8Stats = mkEnableOption "BIND8 like statistics";

    dnssecInterval = mkOption {
      type = types.str;
      default = "1h";
      description = ''
        How often to check whether dnssec key rollover is required
      '';
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Extra nsd config.
      '';
    };

    hideVersion = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether NSD should answer VERSION.BIND and VERSION.SERVER CHAOS class queries.
      '';
    };

    identity = mkOption {
      type = types.str;
      default = "unidentified server";
      description = ''
        Identify the server (CH TXT ID.SERVER entry).
      '';
    };

    interfaces = mkOption {
      type = types.listOf types.str;
      default = [ "127.0.0.0" "::1" ];
      description = ''
        What addresses the server should listen to.
      '';
    };

    ipFreebind = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to bind to nonlocal addresses and interfaces that are down.
        Similar to ip-transparent.
      '';
    };

    ipTransparent = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Allow binding to non local addresses.
      '';
    };

    ipv4 = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to listen on IPv4 connections.
      '';
    };

    ipv4EDNSSize = mkOption {
      type = types.int;
      default = 4096;
      description = ''
        Preferred EDNS buffer size for IPv4.
      '';
    };

    ipv6 = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to listen on IPv6 connections.
      '';
    };

    ipv6EDNSSize = mkOption {
      type = types.int;
      default = 4096;
      description = ''
        Preferred EDNS buffer size for IPv6.
      '';
    };

    logTimeAscii = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Log time in ascii, if false then in unix epoch seconds.
      '';
    };

    nsid = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        NSID identity (hex string, or "ascii_somestring").
      '';
    };

    port = mkOption {
      type = types.port;
      default = 53;
      description = ''
        Port the service should bind do.
      '';
    };

    reuseport = mkOption {
      type = types.bool;
      default = pkgs.stdenv.hostPlatform.isLinux;
      defaultText = literalExpression "pkgs.stdenv.hostPlatform.isLinux";
      description = ''
        Whether to enable SO_REUSEPORT on all used sockets. This lets multiple
        processes bind to the same port. This speeds up operation especially
        if the server count is greater than one and makes fast restarts less
        prone to fail
      '';
    };

    rootServer = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether this server will be a root server (a DNS root server, you
        usually don't want that).
      '';
    };

    roundRobin = mkEnableOption "round robin rotation of records";

    serverCount = mkOption {
      type = types.int;
      default = 1;
      description = ''
        Number of NSD servers to fork. Put the number of CPUs to use here.
      '';
    };

    statistics = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = ''
        Statistics are produced every number of seconds. Prints to log.
        If null no statistics are logged.
      '';
    };

    tcpCount = mkOption {
      type = types.int;
      default = 100;
      description = ''
        Maximum number of concurrent TCP connections per server.
      '';
    };

    tcpQueryCount = mkOption {
      type = types.int;
      default = 0;
      description = ''
        Maximum number of queries served on a single TCP connection.
        0 means no maximum.
      '';
    };

    tcpTimeout = mkOption {
      type = types.int;
      default = 120;
      description = ''
        TCP timeout in seconds.
      '';
    };

    verbosity = mkOption {
      type = types.int;
      default = 0;
      description = ''
        Verbosity level.
      '';
    };

    version = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        The version string replied for CH TXT version.server and version.bind
        queries. Will use the compiled package version on null.
        See hideVersion for enabling/disabling this responses.
      '';
    };

    xfrdReloadTimeout = mkOption {
      type = types.int;
      default = 1;
      description = ''
        Number of seconds between reloads triggered by xfrd.
      '';
    };

    zonefilesCheck = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to check mtime of all zone files on start and sighup.
      '';
    };

    zonefilesWrite = mkOption {
      type = types.int;
      default = 0;
      description = ''
        Write changed secondary zones to their zonefile every N seconds.
        If the zone (pattern) configuration has "" zonefile, it is not written.
        Zones that have received zone transfer updates are written to their zonefile.
        0 disables writing to zone files.
      '';
    };

    keys = mkOption {
      type = types.attrsOf (types.submodule {
        options = {

          algorithm = mkOption {
            type = types.str;
            default = "hmac-sha256";
            description = ''
              Authentication algorithm for this key.
            '';
          };

          keyFile = mkOption {
            type = types.path;
            description = ''
              Path to the file which contains the actual base64 encoded
              key. The key will be copied into "${stateDir}/private" before
              NSD starts. The copied file is only accessibly by the NSD
              user.
            '';
          };

        };
      });
      default = { };
      example = literalExpression ''
        { "tsig.example.org" = {
            algorithm = "hmac-md5";
            keyFile = "/path/to/my/key";
          };
        }
      '';
      description = ''
        Define your TSIG keys here.
      '';
    };

    ratelimit = {

      enable = mkEnableOption "ratelimit capabilities";

      ipv4PrefixLength = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          IPv4 prefix length. Addresses are grouped by netblock.
        '';
      };

      ipv6PrefixLength = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          IPv6 prefix length. Addresses are grouped by netblock.
        '';
      };

      ratelimit = mkOption {
        type = types.int;
        default = 200;
        description = ''
          Max qps allowed from any query source.
          0 means unlimited. With an verbosity of 2 blocked and
          unblocked subnets will be logged.
        '';
      };

      slip = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          Number of packets that get discarded before replying a SLIP response.
          0 disables SLIP responses. 1 will make every response a SLIP response.
        '';
      };

      size = mkOption {
        type = types.int;
        default = 1000000;
        description = ''
          Size of the hashtable. More buckets use more memory but lower
          the chance of hash hash collisions.
        '';
      };

      whitelistRatelimit = mkOption {
        type = types.int;
        default = 2000;
        description = ''
          Max qps allowed from whitelisted sources.
          0 means unlimited. Set the rrl-whitelist option for specific
          queries to apply this limit instead of the default to them.
        '';
      };

    };

    remoteControl = {

      enable = mkEnableOption "remote control via nsd-control";

      controlCertFile = mkOption {
        type = types.path;
        default = "/etc/nsd/nsd_control.pem";
        description = ''
          Path to the client certificate signed with the server certificate.
          This file is used by nsd-control and generated by nsd-control-setup.
        '';
      };

      controlKeyFile = mkOption {
        type = types.path;
        default = "/etc/nsd/nsd_control.key";
        description = ''
          Path to the client private key, which is used by nsd-control
          but not by the server. This file is generated by nsd-control-setup.
        '';
      };

      interfaces = mkOption {
        type = types.listOf types.str;
        default = [ "127.0.0.1" "::1" ];
        description = ''
          Which interfaces NSD should bind to for remote control.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 8952;
        description = ''
          Port number for remote control operations (uses TLS over TCP).
        '';
      };

      serverCertFile = mkOption {
        type = types.path;
        default = "/etc/nsd/nsd_server.pem";
        description = ''
          Path to the server self signed certificate, which is used by the server
          but and by nsd-control. This file is generated by nsd-control-setup.
        '';
      };

      serverKeyFile = mkOption {
        type = types.path;
        default = "/etc/nsd/nsd_server.key";
        description = ''
          Path to the server private key, which is used by the server
          but not by nsd-control. This file is generated by nsd-control-setup.
        '';
      };

    };

    zones = mkOption {
      type = types.attrsOf zoneOptions;
      default = { };
      example = literalExpression ''
        { "serverGroup1" = {
            provideXFR = [ "10.1.2.3 NOKEY" ];
            children = {
              "example.com." = {
                data = '''
                  $ORIGIN example.com.
                  $TTL    86400
                  @ IN SOA a.ns.example.com. admin.example.com. (
                  ...
                ''';
                  };
              "example.org." = {
                data = '''
                  $ORIGIN example.org.
                  $TTL    86400
                  @ IN SOA a.ns.example.com. admin.example.com. (
                  ...
                ''';
                  };
              };
              };

          "example.net." = {
            provideXFR = [ "10.3.2.1 NOKEY" ];
            data = '''
              ...
            ''';
          };
            }
      '';
      description = ''
        Define your zones here. Zones can cascade other zones and therefore
        inherit settings from parent zones. Look at the definition of
        children to learn about inheritance and child zones.
        The given example will define 3 zones (example.(com|org|net).). Both
        example.com. and example.org. inherit their configuration from
        serverGroup1.
      '';
    };
  };

  config = mkIf cfg.enable {

    assertions = singleton {
      assertion = zoneConfigs ? "." -> cfg.rootServer;
      message = "You have a root zone configured. If this is really what you "
        + "want, please enable 'services.nsd.rootServer'.";
    };

    environment = {
      systemPackages = [ nsdPkg ];
      etc."nsd/nsd.conf".source = "${configFile}/nsd.conf";
    };

    users = {
      users."${username}" = {
        description = "NSD service user";
        home = stateDir;
        createHome = true;
        uid = config.ids.uids.nsd;
        group = username;
      };
      groups."${username}".gid = config.ids.gids.nsd;
    };

    systemd = {
      tmpfiles.rules = [ "d ${stateDir} 0700 ${username} - - -" ];

      services = {
        nsd = {
          description = "NSD authoritative only domain name service";

          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          startLimitBurst = 4;
          startLimitIntervalSec = 5 * 60; # 5 mins
          serviceConfig = {
            ExecStart = "${nsdPkg}/sbin/nsd -d -c ${nsdEnv}/nsd.conf";
            StandardError = "null";
            PIDFile = pidFile;
            Restart = "always";
            RestartSec = "4s";
          };

          preStart = let
            copyZoneIncludes = concatLists (mapAttrsToList (zoneName:
              { includes, ... }:
              [ "mkdir -p ${stateDir}/zones/includes-${zoneName}" ] ++ (map
                (file:
                  "cp ${file} ${stateDir}/zones/includes-${zoneName}/${
                    baseNameOf file
                  }")) includes) cfg.zones);
          in ''
            rm -Rf "${stateDir}/private/"
            rm -Rf "${stateDir}/tmp/"

            mkdir -m 0700 -p "${stateDir}/private"
            mkdir -m 0700 -p "${stateDir}/tmp"
            mkdir -m 0700 -p "${stateDir}/var"
            mkdir -m 0711 -p "${stateDir}/run"

            cat > "${stateDir}/don't touch anything in here" << EOF
            Everything in this directory except NSD's state in var and dnssec
            is automatically generated and will be purged and redeployed by
            the nsd.service pre-start script.
            EOF

            chown ${username}:${username} -R "${stateDir}/private"
            chown ${username}:${username} -R "${stateDir}/tmp"
            chown ${username}:${username} -R "${stateDir}/var"
            chown ${username}:${username} -R "${stateDir}/run"

            rm -rf "${stateDir}/zones"
            cp -rL "${nsdEnv}/zones" "${stateDir}/zones"

            ${concatStringsSep "\n" copyZoneIncludes}

            ${copyKeys}

            ${rotateAndSignZones}
          '';
        };

        nsd-dnssec = mkIf dnssec {
          description = "DNSSEC key rollover";

          script = rotateAndSignZones;

          postStop = ''
            /run/current-system/systemd/bin/systemctl kill -s SIGHUP nsd.service
          '';
        };
      };

      timers.nsd-dnssec = mkIf dnssec {
        description = "Automatic DNSSEC key rollover";

        wantedBy = [ "timers.target" ];

        timerConfig = {
          OnActiveSec = cfg.dnssecInterval;
          OnUnitActiveSec = cfg.dnssecInterval;
        };
      };
    };
  };
}
