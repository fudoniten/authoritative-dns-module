{
  description = "Authoritative DNS Server";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.11";
    fudo-lib.url = "github:fudoniten/fudo-nix-lib/25.11";
  };

  outputs = { self, nixpkgs, fudo-lib, ... }: {
    nixosModules = rec {
      default = authoritativeDns;
      authoritativeDns = { ... }: {
        imports = [ ./authoritative-dns.nix fudo-lib.nixosModules.lib ];
      };
    };
  };
}
