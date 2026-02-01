{
  description = "Barleta NixOS Homelab - PowerSpec G913";

  inputs = {
    # Use nixos-unstable for RTX 5080 (Blackwell) driver support
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Secrets management
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative disk partitioning
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, sops-nix, disko, ... }@inputs: {
    # NixOS system configurations
    nixosConfigurations = {
      # PowerSpec G913 - Main homelab host
      g913 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/g913/configuration.nix
          ./hosts/g913/hardware-configuration.nix
          ./hosts/g913/disko.nix
          sops-nix.nixosModules.sops
          disko.nixosModules.disko
        ];
      };
    };

    # Disko configurations for standalone CLI usage
    diskoConfigurations = {
      g913 = import ./hosts/g913/disko.nix { lib = nixpkgs.lib; };
    };

    # Expose overlays if needed
    overlays.default = import ./overlays;
  };
}
