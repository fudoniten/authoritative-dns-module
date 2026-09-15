# Authoritative DNS Module

NixOS module for declarative authoritative DNS server configuration using NSD.

## Features

- Declarative DNS zone configuration via Nix
- DNSSEC support with automatic key management
- Automatic reverse zone generation
- Support for primary, secondary, and mirror zones
- Rich record types (A, AAAA, MX, NS, CNAME, SRV, TXT, SSHFP, PTR)
- Subdomain support with inheritance

## Usage

Import in your flake:

```nix
{
  inputs.authoritative-dns.url = "github:fudoniten/authoritative-dns-module";

  outputs = { self, nixpkgs, authoritative-dns }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        authoritative-dns.nixosModules.default
        {
          services.authoritative-dns = {
            enable = true;
            identity = "ns1.example.com";
            timestamp = "2024010100";
            state-directory = "/var/lib/nsd";

            domains.example-com = {
              domain = "example.com";
              zone = {
                description = "Main domain";
                nameservers = [ "ns1.example.com." ];
                hosts.webserver = {
                  ipv4-address = "192.0.2.10";
                };
              };
            };
          };
        }
      ];
    };
  };
}
```

## Configuration Options

Key options:
- `debug`: Enable debug output during evaluation (default: false)
- `check-zonefiles`: Validate zone files before deployment (default: true)
- `domains`: Attribute set of domain configurations
- `listen-ips`: IPs to listen on (empty = all)
- `listen-port`: DNS port (default: 53)
- `zonefiles-path`: Install zonefiles from here instead of the system closure
  (default: null) -- see below

See module options for full configuration details.

## Deploying zones separately from the system

By default the zonefiles live in the system closure, which means changing one
record moves `system.build.toplevel`: the only way to correct an IP is to
rebuild and deploy the whole host.

They do not have to. `nsd.conf` never names a store path -- every `zonefile:`
line points into the state directory, and the store path is only ever the
*source of a copy* made at startup -- so the config and the zone text can be
two derivations with two rates of change:

| Change | Needs |
|---|---|
| A record: an IP, a CNAME, an MX | the zonefiles alone |
| Adding or removing a zone, or changing `notify`/`provide-xfr`/DNSSEC for one | the system, and the zonefiles |

Set `zonefiles-path` to a path the deployment tool manages, and install
`config.services.fudo-nsd.zonefilesPackage` there:

```nix
services.authoritative-dns.zonefiles-path = "/nix/var/nix/profiles/dns-zones";
```

With deploy-rs, that is a second profile on the same node whose activation
script is one line:

```nix
profiles.dns-zones = {
  user = "root";
  profilePath = "/nix/var/nix/profiles/dns-zones";
  path = deploy-rs.lib.x86_64-linux.activate.custom zonePkg ''
    /run/current-system/sw/bin/nsd-install-zones --reload ${zonePkg}
  '';
};
```

`nsd-install-zones` is installed by this module into the system closure, not
into the deployable half: signing a zone needs that zone's KSK path, which the
host's configuration knows and a directory of zonefiles does not. It copies the
zones into a staging directory, re-signs every DNSSEC zone there, swaps the
live directory in only once all of them check out, and then SIGHUPs nsd.

The profile is laid *over* the copy in the system closure rather than replacing
it, so a zone the profile has not caught up with yet still resolves, nsd always
starts, and the two can be deployed in either order.

## Components

- `authoritative-dns.nix`: Main module interface
- `zone-definition.nix`: Zone schema definitions
- `zone-to-zonefile.nix`: Zone to DNS file converter
- `reverse-zone.nix`: Reverse DNS generator
- `nsd.nix`: NSD service implementation (forked)
