{
  description = "Authoritative DNS Server";

  inputs = { nixpkgs.url = "nixpkgs/nixos-23.05"; };

  outputs = { self, nixpkgs, ... }: {
    nixosModules = rec {
      default = authoritativeDns;
      authoritativeDns = { ... }: { imports = [ ./authoritative-dns.nix ]; };
    };
  };
}
