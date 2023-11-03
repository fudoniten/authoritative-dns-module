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
  };

  imports = [ ./nsd.nix ];

  config = mkIf cfg.enable {
    services.fudo-nsd = {
      enable = true;
      identity = cfg.identity;
      interfaces = cfg.listen-ips;
      stateDirectory = cfg.state-directory;
      zones = let
        forwardZones = mapAttrs' (domain: domainCfg:
          nameValuePair "${domain}." {
            dnssec = domainCfg.ksk.key-file != null;
            ksk.keyFile =
              mkIf (domainCfg.ksk.key-file != null) domainCfg.ksk.key-file;
            data = zoneToZonefile {
              inherit domain;
              inherit (cfg) timestamp;
              inherit (domainCfg) zone;
            };
          }) cfg.domains;
        reverseZones = concatMapAttrs (domain: domainOpts:
          listToAttrs (map (network:
            reverseZonefile {
              inherit domain network;
              inherit (domainOpts.zone) nameservers;
              ipHostMap = cfg.ip-host-map;
              serial = cfg.timestamp;
            }) domainOpts.reverse-zones)) cfg.domains;
      in forwardZones // reverseZones;
    };
  };
}
