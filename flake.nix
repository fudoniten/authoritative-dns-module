{
  description = "Authoritative DNS Server";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-23.05";
    fudo-lib.url = "github:fudoniten/fudo-nix-lib";
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
