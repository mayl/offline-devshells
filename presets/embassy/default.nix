# The `embassy` preset: an offline Embassy environment, ready to use.
#
# A flake-parts module closing over *this* flake's inputs, so a consumer gets the
# pinned embassy tree and chip template without having to declare them. Override
# them from the consuming flake if you want a different tree:
#
#   inputs.offline-devshells.inputs.embassy.follows = "my-embassy";
#   nix develop --override-input offline-devshells/embassy ~/embassy
#
# Everything here is ordinary `offlineShells.embassy` configuration -- there is
# nothing the preset can do that a consumer could not write themselves.
{ inputs }:
{ lib, ... }:
{
  _file = ./default.nix;
  _class = "flake";
  key = "offline-devshells/presets/embassy";

  perSystem =
    { config, pkgs, ... }:
    let
      crates = import ./crates.nix { inherit lib; };

      # Reads back the toolchain and cargo configs this same module defines. Not
      # a cycle: `rust.toolchain` and `rust.modes.<m>.cargoConfig` are computed
      # from the options set below, and nothing they depend on reads `checks` or
      # `bundlePaths`.
      inherit (config.offlineShells.embassy) rust;
      firmware = import ./firmware.nix {
        inherit pkgs lib;
        inherit (rust) toolchain;
        cargoConfigs = lib.mapAttrs (_: m: m.cargoConfig) rust.modes;
      };
    in
    {
      offlineShells.embassy = {
        packages = [
          pkgs.probe-rs-tools
          pkgs.cargo-embassy
          pkgs.cargo-generate
          pkgs.cargo-binutils
        ]
        # nixpkgs builds gdb with --enable-targets=all, so it can debug the
        # Cortex-M ELFs. Linux only: it is not reliably buildable on Darwin, and
        # `nix build` must not fail there.
        ++ lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.gdb;

        rust = {
          # Pinned rather than `stable.latest` so that updating the rust-overlay
          # input can't silently swap the compiler out from under a vendored
          # crate set that was resolved against a particular MSRV.
          version = "1.97.1";

          extensions = [
            "rust-src"
            "rust-analyzer"
            "clippy"
            "rustfmt"
            # rust-objcopy/rust-size dispatch to these, so no separate LLVM
            # (~740 MB) is needed to produce .bin/.hex from an ELF.
            "llvm-tools"
          ];

          # Add a target here if your chip needs one, then re-run `nix build`
          # while online so the matching rust-std lands in the store.
          targets = [
            "thumbv6m-none-eabi" # Cortex-M0/M0+  (RP2040, nRF51, STM32F0/G0/L0)
            "thumbv7m-none-eabi" # Cortex-M3      (STM32F1/F2/L1)
            "thumbv7em-none-eabi" # Cortex-M4/M7   (soft float)
            "thumbv7em-none-eabihf" # Cortex-M4F/M7F (hard float)
            "thumbv8m.base-none-eabi" # Cortex-M23
            "thumbv8m.main-none-eabi" # Cortex-M33     (soft float)
            "thumbv8m.main-none-eabihf" # Cortex-M33F    (nRF5340, RP2350)
          ];

          defaultMode = "crates-io";

          modes.crates-io = {
            description = "published embassy releases";
            crates = crates.cratesIo;
            lockFile = ./locks/crates-io.lock;
            lockPath = "presets/embassy/locks/crates-io.lock";
          };

          modes.git = {
            description = "embassy from the pinned git tree";
            crates = crates.git;
            lockFile = ./locks/git.lock;
            lockPath = "presets/embassy/locks/git.lock";
            vendorHashFile = ./locks/git-vendor-hash.nix;
            vendorHashPath = "presets/embassy/locks/git-vendor-hash.nix";

            # Every embassy-* crate in the pinned tree, including the six marked
            # `publish = false` (embassy-mspm0 among them). Patching a name that
            # crates.io does not have, or giving it a version crates.io has never
            # released, is fine -- cargo takes the patched version as available.
            patchTree = {
              src = inputs.embassy;
              prefix = "embassy-";
            };
          };
        };

        banner = ''

            embassy-generate <name> <chip>   scaffold via cargo-generate
                                             (STM32, nRF, RP2040/RP2350) -- widest coverage
            embassy-new <name> <chip>        scaffold via cargo-embassy (STM32, nRF)
            embassy-from-example <example>   scaffold from embassy's own examples
                                             (every family, incl. MSPM0; needs git mode)
            embassy-mode git|crates-io       published releases vs. the pinned git tree
            cargo build                      build it (vendored crates, no network)
            cargo run                        flash + attach via probe-rs

          The same commands are in the global justfile: jg embassy::generate, and so on.
        '';

        entrypoints = {
          # Wraps `cargo embassy init` and repairs what it emits; see the
          # script's own header for the list of things it has to fix.
          embassy-new = {
            doc = "Scaffold an Embassy project via cargo-embassy (STM32, nRF)";
            params = [
              "name"
              "chip"
              "*flags"
            ];
            file = ./scripts/embassy-new.sh;
            runtimeInputs = [
              pkgs.cargo-embassy
              pkgs.gnused
              pkgs.gawk
            ];
            runtimeEntrypoints = [ "embassy-lock" ];
          };

          embassy-generate = {
            doc = "Scaffold via cargo-generate (STM32, nRF, RP2040/RP2350)";
            params = [
              "name"
              "chip"
              "*flags"
            ];
            file = ./scripts/embassy-generate.sh;
            runtimeInputs = [
              pkgs.cargo-generate
              pkgs.git
              pkgs.gnused
            ];
            substitutions.template = inputs.embassy-template;
            runtimeEntrypoints = [ "embassy-lock" ];
          };

          # The one scaffolder that reaches every embassy target, by copying from
          # the tree's own examples/ directory.
          embassy-from-example = {
            doc = "Scaffold an Embassy project from the pinned tree's examples";
            params = [
              "example"
              ''name=""''
            ];
            file = ./scripts/embassy-from-example.sh;
            runtimeInputs = [
              pkgs.gnused
              pkgs.gawk
              pkgs.findutils
            ];
            substitutions.embassySrc = inputs.embassy;
            runtimeEntrypoints = [
              "embassy-mode"
              "embassy-lock"
            ];
          };

          embassy-lock = {
            doc = "Generate a project's Cargo.lock against the vendored crate set";
            params = [ ''dir="."'' ];
            file = ./scripts/embassy-lock.sh;
            # Copied through writeText rather than referenced as ./locks/... :
            # interpolating a flake-relative path yields a subpath of the whole
            # flake source, so the substituted string -- and therefore this
            # script -- would change on every edit to any file in the flake. Keyed
            # on the lock's content, it only rebuilds when the lock changes.
            substitutions.gitSeedLock = pkgs.writeText "seed-git-Cargo.lock" (
              builtins.readFile ./locks/git.lock
            );
            runtimeEntrypoints = [ "embassy-mode" ];
          };
        };

        # The two example projects: proof that both vendored sets really compile,
        # and something to flash immediately.
        bundlePaths = {
          embassy-src = inputs.embassy;
          embassy-template = inputs.embassy-template;
          example-firmware = firmware.blinky;
          example-firmware-mspm0 = firmware.blinkyMspm0;
        };
      };

      checks = {
        embassy-firmware = firmware.blinky;
        embassy-firmware-mspm0 = firmware.blinkyMspm0;
      };
    };
}
