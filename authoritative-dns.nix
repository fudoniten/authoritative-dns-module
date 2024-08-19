{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.authoritative-dns;

  zoneOpts = import ./zone-definition.nix { inherit lib; };

  zoneToZonefile = import ./zone-to-zonefile.nix { inherit lib; };

  reverseZonefile = import ./reverse-zone.nix { inherit pkgs; };

  domainOpts = { name, ... }: {
    options = with types; {
      domain = mkOption {
        type = str;
        description = "Domain name.";
        default = name;
      };

      ksk = {
        key-file = mkOption {
          type = nullOr str;
          description =
            "Key-signing key for this zone. DNSSEC disabled when null.";
          default = null;
        };
      };

      zone = mkOption {
        type = submodule zoneOpts;
        description = "Definition of network zone to be served.";
      };

      reverse-zones = mkOption {
        type = listOf str;
        description =
          "List of subnets for which to generate reverse lookup zones.";
        default = [ ];
      };

      notify = {
        ipv4 = mkOption {
          type = listOf str;
          description = "List of IPv4 addresses to notify of changes.";
          default = [ ];
        };

        ipv6 = mkOption {
          type = listOf str;
          description = "List of IPv6 addresses to notify of changes.";
          default = [ ];
        };
      };
    };
  };

in {
  options.services.authoritative-dns = with types; {
    enable = mkEnableOption "Enable authoritative DNS service.";

    identity = mkOption {
      type = str;
      description = "The identity (CH TXT ID.SERVER) of this host.";
    };

    domains = mkOption {
      type = attrsOf (submodule domainOpts);
      default = { };
      description = "A map of domain to domain options.";
    };

    listen-ips = mkOption {
      type = listOf str;
      description =
        "List of IP addresses on which to listen. If empty, listen on all addresses.";
      default = [ ];
    };

    listen-port = mkOption {
      type = port;
      description = "Port on which to listen for IP requests.";
      default = 53;
    };

    state-directory = mkOption {
      type = str;
      description =
        "Path on which to store nameserver state, including DNSSEC keys.";
    };

    timestamp = mkOption {
      type = str;
      description = "Timestamp to attach to zone record.";
    };

    ip-host-map = mkOption {
      type = attrsOf str;
      description =
        "Map of IP address to authoritative hostname. Unneeded hosts will be ignored.";
      default = { };
    };

    mirrored-domains = mkOption {
      type = attrsOf str;
      description = "Map of domain name to primary server IP.";
      default = { };
    };

    trusted-networks = mkOption {
      type = listOf str;
      description = "List of whitelisted networks for transfers.";
      default = [ ];
    };
  };

  imports = [ ./nsd.nix ];

  config = mkIf cfg.enable {
    services.fudo-nsd = {
      enable = true;
      identity = cfg.identity;
      interfaces = cfg.listen-ips;
      port = cfg.listen-port;
      stateDirectory = cfg.state-directory;
      zones = let
        forwardZones = mapAttrs' (domain:
          { ksk, zone, notify, ... }:
          nameValuePair "${domain}." {
            dnssec = ksk.key-file != null;
            ksk.keyFile = ksk.key-file;
            provideXFR = (map (ns: "${ns}/32 NOKEY") notify.ipv4)
              ++ (map (ns: "${ns}/64 NOKEY") notify.ipv6)
              ++ cfg.trusted-networks;
            notify = map (ns: "${ns} NOKEY") (notify.ipv4 ++ notify.ipv6);
            notifyRetry = 5;
            data = let
              zoneData = zoneToZonefile {
                inherit domain;
                inherit (cfg) timestamp;
                inherit zone;
              };
            in trace zoneData zoneData;
          }) cfg.domains;
        reverseZones = concatMapAttrs (domain:
          { ksk, zone, reverse-zones, notify, ... }:
          listToAttrs (map (network:
            reverseZonefile {
              inherit domain network notify;
              inherit (zone) nameservers;
              ipHostMap = cfg.ip-host-map;
              serial = cfg.timestamp;
            }) reverse-zones)) cfg.domains;
        secondaryZones = mapAttrs (domain: masterIp: {
          allowNotify = [ "${masterIp}" ];
          requestXFR = [ "${masterIp} NOKEY" ];
          allowAXFRFallback = true;
          # Bare-bones zone definition prior to getting full records
          data = ''
            $ORIGIN ${domain}.
            $TTL 3h

            @ IN SOA ns1.${domain}. hostmaster.${domain}. (
              ${toString cfg.timestamp}
              30m
              2m
              3w
              5m)
          '';
        }) cfg.mirrored-domains;
      in forwardZones // reverseZones // secondaryZones;
    };
  };
}
