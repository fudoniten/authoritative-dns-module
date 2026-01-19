{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.authoritative-dns;

  zoneOpts = import ./zone-definition.nix { inherit lib; };

  zoneToZonefile = import ./zone-to-zonefile.nix { inherit lib; };

  reverseZonefile = import ./reverse-zone.nix { inherit pkgs; };

  # Input validation functions
  isValidIpv4 = ip:
    let parts = splitString "." ip;
    in (length parts == 4) && all (p:
      let n = toInt p;
      in n >= 0 && n <= 255) parts;

  isValidIpv6 = ip:
    # Basic IPv6 validation - contains colons and valid hex characters
    builtins.match "[0-9a-fA-F:]+(/[0-9]+)?" ip != null;

  isValidDomain = domain:
    # Basic domain validation - alphanumeric, hyphens, dots, and underscores
    builtins.match "[a-zA-Z0-9][a-zA-Z0-9._-]*" domain != null;

  isValidTimestamp = ts:
    # Timestamp should be numeric and reasonable length (typically 10 digits for YYYYMMDDNN)
    builtins.match "[0-9]{8,12}" ts != null;

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

      includes = mkOption {
        type = listOf str;
        description =
          "List of files to include at the end of the zonefile. NOTE: incompatible with DNSSEC and zone checking.";
        default = [ ];
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

    check-zonefiles = mkOption {
      type = bool;
      description = "Perform zonefile check before deploying.";
      default = true;
    };

    debug = mkOption {
      type = bool;
      description = "Enable debug output during evaluation.";
      default = false;
    };
  };

  imports = [ ./nsd.nix ];

  config = mkIf cfg.enable {
    # Input validation assertions
    assertions = [
      {
        assertion = isValidTimestamp cfg.timestamp;
        message = "services.authoritative-dns.timestamp must be a numeric string of 8-12 digits (e.g., '2024010100')";
      }
      {
        assertion = all isValidDomain (attrNames cfg.domains);
        message = "All domain names in services.authoritative-dns.domains must be valid domain names";
      }
      {
        assertion = all (ip: isValidIpv4 ip || isValidIpv6 ip) cfg.listen-ips;
        message = "All IPs in services.authoritative-dns.listen-ips must be valid IPv4 or IPv6 addresses";
      }
      {
        assertion = all (ip: isValidIpv4 ip || isValidIpv6 ip) (attrNames cfg.ip-host-map);
        message = "All IPs in services.authoritative-dns.ip-host-map must be valid IPv4 or IPv6 addresses";
      }
    ];

    networking.firewall = {
      allowedTCPPorts = [ cfg.listen-port ];
      allowedUDPPorts = [ cfg.listen-port ];
    };

    services.fudo-nsd = {
      enable = true;
      identity = cfg.identity;
      interfaces = cfg.listen-ips;
      port = cfg.listen-port;
      stateDirectory = cfg.state-directory;
      checkZonefiles = cfg.check-zonefiles;
      zones = let
        forwardZones = mapAttrs' (domain:
          { ksk, zone, notify, includes, ... }:
          nameValuePair "${domain}." {
            dnssec = ksk.key-file != null;
            ksk.keyFile = ksk.key-file;
            provideXFR = (map (ns: "${ns}/32 NOKEY") notify.ipv4)
              ++ (map (ns: "${ns}/64 NOKEY") notify.ipv6)
              ++ (map (net: "${net} NOKEY") cfg.trusted-networks);
            notify = map (ns: "${ns} NOKEY") (notify.ipv4 ++ notify.ipv6);
            notifyRetry = 5;
            inherit includes;
            data = let
              zoneData = zoneToZonefile {
                inherit domain;
                inherit (cfg) timestamp;
                inherit zone;
              };
            in if cfg.debug then trace zoneData zoneData else zoneData;
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

        allZones = forwardZones // reverseZones // secondaryZones;
      in if cfg.debug then trace (concatStringsSep " :: " (attrNames allZones)) allZones else allZones;
    };
  };
}
