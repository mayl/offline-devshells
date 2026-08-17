{
  description = "flake-parts modules for development environments that keep working with the network unplugged";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    vm-parts.url = "github:mayl/vm-parts";
    vm-parts.inputs.nixpkgs.follows = "nixpkgs";
    vm-parts.inputs.flake-parts.follows = "flake-parts";

    nix-global-just.url = "github:mayl/nix-global-just";
    nix-global-just.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # The embassy source tree itself, for building against unreleased crates.
    # `flake.lock` pins the revision, so this is as reproducible as any other
    # input:
    #   nix flake update embassy                        move to current main
    #   nix flake lock --override-input embassy ...      pin a branch, tag or fork
    #   nix develop --override-input embassy ~/embassy   try a local checkout
    embassy = {
      url = "github:embassy-rs/embassy";
      flake = false;
    };

    # The broadest of the generators embassy's docs list: every STM32 in
    # stm32-data, the nRF families, and the whole RP2040/RP2350 line that
    # cargo-embassy does not handle. Pinned so `cargo generate --path` works with
    # no network.
    embassy-template = {
      url = "github:lulf/embassy-template";
      flake = false;
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { withSystem, config, ... }:
      let
        # The machine, minus anything format-specific: reused by ./vm/test.nix so
        # the test boots the same configuration the appliance ships.
        machineModules = [
          ./vm/machine.nix
          inputs.home-manager.nixosModules.home-manager
          (withSystem "x86_64-linux" (
            { config, ... }:
            {
              imports = [ config.offlineShells.embassy.nixosModule ];

              home-manager.users.larry = {
                imports = [
                  inputs.nix-global-just.homeManagerModules.default
                  # Only *defines* programs.globalJust options; the module
                  # declaring them is the import above.
                  config.offlineShells.embassy.homeModule
                ];
                home.stateVersion = "25.11";
              };
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
            }
          ))
        ];
      in
      {
        imports = [
          flake-parts.flakeModules.flakeModules
          inputs.vm-parts.flakeModules.default

          # Dogfood: the module is type-checked by our own eval, and the embassy
          # environment below is built with exactly the module a consumer gets.
          ./flake-module.nix
          (import ./presets/embassy { inherit inputs; })
        ];

        systems = [
          "x86_64-linux"
          "aarch64-linux"
          "x86_64-darwin"
          "aarch64-darwin"
        ];

        flake.flakeModules = {
          default = ./flake-module.nix;
          offlineShells = ./flake-module.nix;

          # A function of *our* inputs, not the consumer's: the pinned embassy
          # tree and chip template are what make the preset a preset. Override
          # them with `inputs.offline-devshells.inputs.embassy.follows`.
          embassy = import ./presets/embassy { inherit inputs; };
        };

        flake.templates.default = {
          path = ./template;
          description = "A flake-parts flake with one offline Rust environment and a VM to put it in.";
          welcomeText = ''
            # offline-devshells

            One environment is declared in `flake.nix` under `offlineShells.myEnv`.

                nix build .#myEnv        realise the whole environment into the store
                nix develop .#myEnv      enter it
                nix run .#myEnv-refresh-seed   re-resolve the crate set (needs network)

            Add crates under `rust.modes.<mode>.crates.<member>`, then re-run
            refresh-seed and commit the updated lock.
          '';
        };

        # The offline embedded-Rust box. Its environment comes from the embassy
        # preset imported above; ./vm/machine.nix describes only the machine.
        vms.embassy-box = {
          system = "x86_64-linux";
          modules = machineModules;

          # Merged into the built-in `virtualbox` format rather than replacing
          # it, which is why the sizing can live here instead of in machine.nix.
          formatModules.virtualbox =
            { lib, ... }:
            {
              virtualbox.memorySize = 4096;
              virtualbox.params.cpus = 4;
              virtualbox.vmName = "embassy-offline";
              image.baseName = "embassy-offline";

              # nixpkgs' virtualbox-image.nix turns guest additions on
              # unconditionally -- not `mkDefault` -- and as of the pinned
              # nixpkgs the 7.2.14 additions do not compile against any kernel in
              # the tree: `vbox_fb.c` still calls `drm_fb_helper_alloc_info`
              # through a declaration the kernel no longer provides, so the build
              # dies with `-Wint-conversion`. Hence `mkForce` rather than a
              # polite override.
              #
              # What that costs: shared folders (vboxsf), clipboard sharing and
              # guest time sync. What it does not cost: USB passthrough of a debug
              # probe, which is a host-side VirtualBox feature. Move code in and
              # out over SSH instead -- `services.openssh` is on.
              #
              # Drop this once the additions build again.
              virtualisation.virtualbox.guest.enable = lib.mkForce false;
            };

          formats = [
            "vbox" # nix build .#embassy-box.vbox.file  -> the .ova
            "vm" # nix build .#embassy-box.vm         -> a qemu run script
          ];
        };

        perSystem =
          {
            system,
            pkgs,
            lib,
            ...
          }:
          {
            # The rust backend needs `pkgs.rust-bin`.
            _module.args.pkgs = import inputs.nixpkgs {
              inherit system;
              overlays = [ inputs.rust-overlay.overlays.default ];
            };

            formatter = pkgs.nixfmt-tree or pkgs.nixfmt-rfc-style;

            # Outside `checks` on purpose: booting it means materialising the
            # whole offline closure into a disk image, which `nix flake check`
            # has no business doing.
            packages = lib.optionalAttrs (system == "x86_64-linux") {
              embassy-box-test = import ./vm/test.nix { inherit pkgs machineModules; };
            };
          };
      }
    );
}
