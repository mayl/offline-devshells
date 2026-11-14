{
  description = "flake-parts modules for development environments that keep working with the network unplugged";

  # Only what the modules, the embassy preset and this repository's own checks
  # need. The appliance's inputs (vm-parts, Home Manager, nix-global-just) live
  # in ./dev/flake.nix and are loaded into a partition, so they never land in a
  # consumer's lock.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    # Only for this repository's own `pkgs`; the modules use the consumer's.
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    # The embassy source tree itself, for building against unreleased crates.
    # `flake.lock` pins the revision, so this is as reproducible as any other
    # input:
    #   nix flake update embassy                        move to current main
    #   nix flake lock --override-input embassy ...      pin a branch, tag or fork
    #   nix develop --override-input embassy ~/embassy   try a local checkout
    # Moving it means re-running `embassy-refresh-seed`: see "Bumping" in the
    # README.
    embassy = {
      url = "github:embassy-rs/embassy";
      flake = false;
    };

    # The broadest of the generators embassy's docs list: every STM32 in
    # stm32-data, the nRF families, and the whole RP2040/RP2350 line. Pinned so
    # `cargo generate --path` works with no network.
    embassy-template = {
      url = "github:lulf/embassy-template";
      flake = false;
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      let
        # A function of *our* inputs, not the consumer's: the pinned embassy
        # tree and chip template are what make the preset a preset.
        embassyPreset = import ./presets/embassy { inherit inputs; };
      in
      {
        imports = [
          flake-parts.flakeModules.flakeModules
          flake-parts.flakeModules.partitions

          # Dogfood: the module is type-checked by our own eval, and the embassy
          # environment below is built with exactly the module a consumer gets.
          ./flake-module.nix
          embassyPreset
        ];

        systems = [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
        ];

        flake.flakeModules = {
          default = ./flake-module.nix;
          offlineShells = ./flake-module.nix;
          embassy = embassyPreset;
        };

        flake.templates.default = {
          path = ./template;
          description = "A flake-parts flake with one offline Rust environment.";
          welcomeText = ''
            # offline-devshells

            One environment is declared in `flake.nix` under `offlineShells.myEnv`.
            Its lock ships as a placeholder, so first, with network:

                git init && git add -A          flakes only see tracked files
                nix run .#myEnv-refresh-seed    resolve the crate set
                git add locks/ && git commit

            Then, network or not:

                nix build .#myEnv               realise the whole environment into the store
                nix develop .#myEnv             enter it

            Add crates under `rust.modes.<mode>.crates.<member>`, then re-run
            refresh-seed and commit the updated lock.
          '';
        };

        # The appliance and its boot test: see ./dev/flake-module.nix.
        #
        # Not `extraInputsFlake = ./dev`: flake-parts loads a path by copying
        # it to the store as a separate `-dev` path, and `nix flake check
        # --no-build` evaluates read-only, so on a store that has never seen
        # that copy (CI, a fresh clone) it fails with "path ...-dev is not
        # valid". Pointing at the directory inside our own, already-fetched
        # source needs no copy.
        partitions.dev = {
          extraInputs =
            (import "${flake-parts}/vendor/flake-compat" {
              src.outPath = "${inputs.self}/dev";
              system = throw "the dev partition's inputs are loaded in pure mode; `system` is not available";
            }).outputs.inputs;
          module.imports = [ ./dev/flake-module.nix ];
        };
        partitionedAttrs = {
          embassy-box = "dev";
          legacyPackages = "dev";
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

            formatter = pkgs.nixfmt-tree;

            checks = {
              generic-layer = import ./tests/generic-layer.nix { inherit pkgs lib; };
              rust-backend = import ./tests/rust-backend.nix { inherit pkgs lib; };
            };
          };
      }
    );
}
