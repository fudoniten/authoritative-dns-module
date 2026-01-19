{ lib, ... }:

with lib;
let

  networkHostOpts = { name, ... }: {
    options = with types; {
      hostname = mkOption {
        type = str;
        description = "Hostname.";
        default = name;
      };
      ipv4-address = mkOption {
        type = nullOr str;
        description = "The V4 IP of a given host, if any.";
        default = null;
      };

      ipv6-address = mkOption {
        type = nullOr str;
        description = "The V6 IP of a given host, if any.";
        default = null;
      };

      mac-address = mkOption {
        type = nullOr str;
        description =
          "The MAC address of a given host, if desired for IP reservation.";
        default = null;
      };

      description = mkOption {
        type = nullOr str;
        description = "Description of the host.";
        default = null;
      };

      sshfp-records = mkOption {
        type = listOf str;
        description = "List of SSHFP records for this host.";
        default = [ ];
      };
    };
  };

  srvRecordEntry = {
    options = with types; {
      host = mkOption {
        type = str;
        description = "Host providing service.";
        example = "my-host.domain.com";
      };

      port = mkOption {
        type = port;
        description = "Port for service on this host.";
        example = 55;
      };

      priority = mkOption {
        type = int;
        description = "Priority to give this record.";
        default = 0;
      };

      weight = mkOption {
        type = int;
        description =
          "Weight to give this record, among records of equivalent priority.";
        default = 5;
      };
    };
  };

  zoneOpts = {
    options = with types; {
      hosts = mkOption {
        type = attrsOf (submodule networkHostOpts);
        description = "Hosts on the local network, with relevant settings.";
        default = { };
      };

      nameservers = mkOption {
        type = listOf str;
        description = "List of zone nameservers.";
        example = [ "ns1.domain.com." "10.0.0.1" ];
        default = [ ];
      };

      srv-records = mkOption {
        type = attrsOf (attrsOf (listOf (submodule srvRecordEntry)));
        description = "SRV records for this zone.";
        example = {
          tcp = {
            xmpp = [{
              host = "my-host.com";
              port = 55;
            }];
          };
        };
      };

      metric-records = mkOption {
        type = attrsOf (listOf (submodule srvRecordEntry));
        description = "Map of metric types to a list of SRV host records.";
        example = {
          node = [{
            host = "my-host.my-domain.com";
            port = 443;
          }];
          postfix = [{
            host = "my-mailserver.my-domain.com";
            port = 443;
          }];
        };
        default = { };
      };

      aliases = mkOption {
        type = attrsOf str;
        description =
          "A mapping of host-alias -> hostname to add to the domain record.";
        default = { };
        example = {
          my-alias = "some-host";
          external-alias = "host-outside.domain.com.";
        };
      };

      verbatim-dns-records = mkOption {
        type = listOf str;
        description = "Records to be inserted verbatim into the DNS zone.";
        default = [ ];
        example = [ "some-host IN CNAME target-host" ];
      };

      dmarc-report-address = mkOption {
        type = nullOr str;
        description = "Email address to receive DMARC reports, if any.";
        example = "admin-user@domain.com";
        default = null;
      };

      default-host = mkOption {
        type = nullOr (submodule networkHostOpts);
        description =
          "Network properties of the default host for this domain, if any.";
        default = null;
      };

      mx = mkOption {
        type = listOf str;
        description = "A list of mail servers which serve this domain.";
        default = [ ];
      };

      gssapi-realm = mkOption {
        type = nullOr str;
        description = "Kerberos GSSAPI realm of the zone.";
        default = null;
      };

      default-ttl = mkOption {
        type = str;
        description = "Default time-to-live for this zone.";
        default = "3h";
      };

      host-record-ttl = mkOption {
        type = str;
        description = "Default time-to-live for hosts in this zone";
        default = "1h";
      };

      description = mkOption {
        type = str;
        description = "Description of this zone.";
      };

      subdomains = mkOption {
        type = attrsOf (submodule zoneOpts);
        description = "Subdomains of the current zone.";
        default = { };
      };
    };
  };

in zoneOpts
