# The `embassy` preset: an offline Embassy environment, ready to use.
#
# A flake-parts module closing over *this* flake's inputs, so a consumer gets the
# pinned embassy tree and chip template without having to declare them.
#
# Everything here is ordinary `offlineShells.embassy` configuration -- there is
# nothing the preset can do that a consumer could not write themselves.
#
# Its locks live in this repository. Used as-is from another flake that is
# fine: the pinned locks match the pinned tree. To change the crate set, or move
# git mode onto a different embassy tree, the locks have to move into *your*
# repository, because refresh-seed rewrites them -- see `embassyPreset.locksDir`.
{ inputs }:
{
  lib,
  config,
  ...
}:
let
  top = config;
  cfg = config.embassyPreset;
in
{
  _file = ./default.nix;
  _class = "flake";
  key = "offline-devshells/presets/embassy";

  # The preset is `offlineShells.embassy`, so it needs the module that declares
  # `offlineShells`. Importing it here means one import is enough; it is keyed,
  # so importing `flakeModules.default` as well is harmless.
  imports = [ ../../flake-module.nix ];

  options.embassyPreset = {
    locksDir = lib.mkOption {
      type = lib.types.path;
      default = ./locks;
      defaultText = lib.literalMD "offline-devshells' own `presets/embassy/locks`";
      example = lib.literalExpression "./locks/embassy";
      description = ''
        Directory holding the preset's `crates-io.lock`, `git.lock` and
        `git-vendor-hash.nix`.

        The default -- this flake's own copies -- is right as long as you use
        the preset unchanged. Point it at a directory in your repository (start
        by copying offline-devshells' files there) when you widen the crate set
        or override the `embassy` input, then run `embassy-refresh-seed`.
      '';
    };

    locksPath = lib.mkOption {
      type = lib.types.str;
      defaultText = lib.literalMD "{option}`locksDir`, relative to the root of the flake it lives in";
      example = "locks/embassy";
      description = ''
        {option}`locksDir` relative to the repository root: where
        `embassy-refresh-seed` writes. Derived from {option}`locksDir` by
        stripping the flake's store prefix, which is right whenever the flake is
        the repository root; set it by hand otherwise.
      '';
    };
  };

  config.embassyPreset.locksPath = lib.mkOptionDefault (
    let
      # /nix/store/<hash>-source/<path in repo>
      parts = lib.splitString "/" (toString cfg.locksDir);
    in
    if lib.hasPrefix "${builtins.storeDir}/" (toString cfg.locksDir) && lib.length parts > 4 then
      lib.concatStringsSep "/" (lib.drop 4 parts)
    else
      throw "offline-devshells: cannot derive `embassyPreset.locksPath` from ${toString cfg.locksDir}; set it explicitly."
  );

  config.perSystem =
    { config, pkgs, ... }:
    let
      # Versions for the crates embassy publishes are derived, not written in
      # crates.nix; see ./versions.nix.
      pinned = lib.importJSON ./versions.json;
      versions = import ./versions.nix {
        inherit lib pinned;
        embassySrc = inputs.embassy;
      };
      crates = versions.resolve (import ./crates.nix { inherit lib; });

      # Reads back the toolchain and cargo configs this same module defines. Not
      # a cycle: `rust.toolchain` and `rust.modes.<m>.cargoConfig` are computed
      # from the options set below, and nothing they depend on reads `checks` or
      # `bundlePaths`.
      inherit (config.offlineShells.embassy) rust;
      firmware = import ./firmware.nix {
        inherit pkgs lib;
        inherit (rust) toolchain;
        cargoConfigs = lib.mapAttrs (_: m: m.cargoConfig) rust.modes;
        gitSeedLock = top.embassyPreset.locksDir + "/git.lock";
        inherit versions;
        derivedVersions = crates.versions;
      };

      lock = file: {
        lockFile = top.embassyPreset.locksDir + "/${file}";
        lockPath = "${top.embassyPreset.locksPath}/${file}";
      };
    in
    {
      offlineShells.embassy = {
        packages = [
          pkgs.probe-rs-tools
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
          # crate set that was resolved against a particular MSRV. Kept in
          # versions.json, which `embassy-bump` moves to the toolchain the
          # pinned embassy tree's rust-toolchain.toml asks for (never down).
          version = pinned.rust;

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
          }
          // lock "crates-io.lock";

          modes.git = {
            description = "embassy from the pinned git tree";
            crates = crates.git;
            vendorHashFile = top.embassyPreset.locksDir + "/git-vendor-hash.nix";
            vendorHashPath = "${top.embassyPreset.locksPath}/git-vendor-hash.nix";

            # Every embassy-* crate in the pinned tree, including the six marked
            # `publish = false` (embassy-mspm0 among them). Patching a name that
            # crates.io does not have, or giving it a version crates.io has never
            # released, is fine -- cargo takes the patched version as available.
            patchTree = {
              src = inputs.embassy;
              prefix = "embassy-";
            };
          }
          // lock "git.lock";
        };

        # The pinned sources, named so they can be pointed at -- an editor, a
        # `cargo doc` path, a grep through the HAL you are actually building
        # against. `embassy-from-example` uses its own substituted copy of the
        # first one rather than reading this, so that it keeps working when the
        # environment is not applied.
        env = {
          EMBASSY_SRC = "${inputs.embassy}";
          EMBASSY_TEMPLATE_SRC = "${inputs.embassy-template}";
        };

        banner = ''

            embassy-generate <name> <chip>   scaffold via cargo-generate
                                             (STM32, nRF, RP2040/RP2350)
            embassy-from-example <example>   scaffold from embassy's own examples
                                             (every family, incl. MSPM0; needs git mode)
            embassy-mode git|crates-io       published releases vs. the pinned git tree
            cargo build                      build it (vendored crates, no network)
            cargo run                        flash + attach via probe-rs

          To get back in from anywhere, with no flake in sight: embassy-shell,
          or jg embassy::shell from the global justfile.
        '';

        entrypoints = {
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
              builtins.readFile (top.embassyPreset.locksDir + "/git.lock")
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
