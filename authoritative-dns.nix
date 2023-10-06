{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.authoritative-dns;

  zoneOpts = import ./zone-definition.nix { inherit lib; };

  zoneToZonefile = import ./zone-to-zonefile.nix { inherit lib; };

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
  };

  imports = [ ./nsd.nix ];

  config = mkIf cfg.enable {
    services.fudo-nsd = {
      enable = true;
      identity = cfg.identity;
      interfaces = cfg.listen-ips;
      stateDirectory = cfg.state-directory;
      zones = mapAttrs' (dom: domCfg:
        nameValuePair "${dom}." {
          dnssec = domCfg.ksk.key-file != null;
          ksk.keyFile = mkIf (domCfg.ksk.key-file != null) domCfg.ksk.key-file;
          data = zoneToZonefile cfg.timestamp dom domCfg.zone;
        }) cfg.domains;
    };
  };
}
