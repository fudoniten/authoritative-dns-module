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

See module options for full configuration details.

## Components

- `authoritative-dns.nix`: Main module interface
- `zone-definition.nix`: Zone schema definitions
- `zone-to-zonefile.nix`: Zone to DNS file converter
- `reverse-zone.nix`: Reverse DNS generator
- `nsd.nix`: NSD service implementation (forked)
