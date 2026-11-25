{
  description = "Nix package and NixOS module for the immurok BLE fingerprint key";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems =
        function: nixpkgs.lib.genAttrs supportedSystems (system: function nixpkgs.legacyPackages.${system});

      # NixOS module whose `package` default is this flake's build for the host system.
      immurokModule =
        { pkgs, lib, ... }:
        {
          imports = [ ./nix/module.nix ];
          services.immurok.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.immurok;
        };

      # Evaluation-only NixOS system enabling the module, used by `checks`.
      evaluationSystemFor =
        system:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            immurokModule
            {
              boot.loader.grub.enable = false;
              fileSystems."/" = {
                device = "/dev/disk/by-label/nixos";
                fsType = "ext4";
              };
              system.stateVersion = "25.11";
              hardware.bluetooth.enable = true;
              services.immurok = {
                enable = true;
                pam.services = [
                  "sudo"
                  "polkit-1"
                ];
              };
            }
          ];
        };
    in
    {
      packages = forAllSystems (pkgs: rec {
        immurok = pkgs.callPackage ./nix/package.nix { };
        default = immurok;
      });

      overlays.default = final: previous: {
        immurok = final.callPackage ./nix/package.nix { };
      };

      nixosModules = {
        immurok = immurokModule;
        default = immurokModule;
      };

      checks = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          evaluatedSystem = evaluationSystemFor system;
        in
        {
          package = self.packages.${system}.immurok;
          # Building the generated /etc forces evaluation of units, PAM files, D-Bus and polkit config.
          module-evaluation = evaluatedSystem.config.system.build.etc;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
