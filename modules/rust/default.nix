# The Rust backend for `offlineShells.<name>`.
#
# Two things have to be in the store for offline Rust development to work: a
# toolchain with `rust-std` for every target you will ever build for, and every
# crate the projects resolve to. This module owns both, plus the cargo
# configuration that points at them and hard-disables the network.
#
# The crate half is organised around *modes*. A mode is one self-consistent
# resolution -- a crate set, its lock, an optional `[patch.crates-io]` table, and
# a vendor directory. Modes cannot be merged, because cargo allows exactly one
# replacement for crates.io; they are switched between at run time by the
# generated `<prefix>-mode` command.
{ pkgs, lib }:
{
  config,
  shellName,
  commandPrefix,
  ...
}:
let
  inherit (lib) mkOption types;

  seedLib = import ./seed.nix { inherit lib pkgs; };

  depType = types.submodule {
    options = {
      version = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "0.9";
        description = "Semver requirement, as it would appear in a `Cargo.toml`.";
      };
      package = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "embassy-executor";
        description = ''
          Real crate name, when the attribute name is a rename. This is how two
          majors of the same crate are seeded side by side -- give one of them an
          attribute name like `embassy-executor-09` and set `package` to the real
          name.
        '';
      };
      features = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Features to enable.

          Features matter to vendoring only insofar as they gate *optional
          dependencies*: enabling one that merely flips a `cfg` changes nothing
          about what gets fetched. So feature lists here should be generous --
          the cost of an extra feature is a few more crates in the vendor
          directory, and the cost of a missing one is a project that will not
          resolve offline.
        '';
      };
      defaultFeatures = mkOption {
        type = types.bool;
        default = true;
        description = "Rendered as `default-features = false` when off.";
      };
    };
  };

  # `heapless = "0.9"` as shorthand for `heapless = { version = "0.9"; }`.
  coercedDepType = types.coercedTo types.str (v: { version = v; }) depType;

  modeType = types.submodule (
    { name, config, ... }:
    {
      options = {
        description = mkOption {
          type = types.str;
          default = "";
          example = "published releases";
          description = "One-line summary, shown by the `<prefix>-mode` command.";
        };

        crates = mkOption {
          type = types.attrsOf (types.attrsOf coercedDepType);
          default = { };
          example = lib.literalExpression ''
            {
              common.heapless = { version = "0.9"; features = [ "serde" ]; };
              stm32.embassy-stm32 = { version = "0.6"; features = [ "stm32f411ce" ]; };
            }
          '';
          description = ''
            The offline crate set, as `<member>.<crate>`. Members become packages
            of a generated workspace that is never compiled; see ./seed.nix for
            why they are split up at all.

            Extend it from anywhere -- another module adding
            `crates.common.my-driver.version = "0.3"` widens the vendored set,
            which is the whole point of declaring it here rather than in a
            checked-in `Cargo.toml`.

            Changing this invalidates {option}`lockFile`: re-run
            `<prefix>-refresh-seed` (online) and commit the result.
          '';
        };

        extraManifest = mkOption {
          type = types.attrsOf types.lines;
          default = { };
          description = ''
            Raw TOML appended inside each member's `[dependencies]` table. The
            escape hatch for a dependency the structured options cannot express.
          '';
        };

        edition = mkOption {
          type = types.str;
          default = "2021";
          description = "`workspace.package.edition` of the generated seed.";
        };

        lockFile = mkOption {
          type = types.path;
          description = ''
            The committed `Cargo.lock` for this mode. Read at evaluation time and
            turned into the vendor directory.

            It has to be a real file in the consuming repository: resolving needs
            network, vendoring must not, so the resolution is done once by
            `<prefix>-refresh-seed` and its result is checked in.
          '';
        };

        lockPath = mkOption {
          type = types.str;
          example = "locks/crates-io.lock";
          description = ''
            Where `<prefix>-refresh-seed` writes the re-resolved lock, relative to
            the repository root. Separate from {option}`lockFile` because that one
            is a store path by the time anything can read it, and store paths are
            not writable.
          '';
        };

        vendorHashFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Fixed-output hash covering everything vendored for this mode, as a
            file containing a single SRI string.

            Setting it switches the vendorer from `importCargoLock` to
            `fetchCargoVendor`, which is what a lock with **git** sources needs: a
            `Cargo.lock` pins a git dependency by revision without recording a
            checksum, so `importCargoLock` would need a hand-maintained hash per
            repository plus hand-written `[source."git+..."]` stanzas.
            `fetchCargoVendor` covers all of it under this one hash and emits a
            complete config.

            Leave it null for a crates.io-only lock, where the checksums already
            in the lock are enough and there is no hash to keep in sync.
          '';
        };

        vendorHashPath = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "locks/git-vendor-hash.nix";
          description = "Where `<prefix>-refresh-seed` writes the refreshed hash, relative to the repository root.";
        };

        patch = mkOption {
          type = types.attrsOf types.str;
          default = { };
          example = lib.literalExpression ''{ my-crate = "/path/to/my-crate"; }'';
          description = ''
            Explicit `[patch.crates-io]` entries, as crate name to path.

            Patching a name crates.io does not have, or giving it a version
            crates.io has never released, is fine: cargo takes the patched version
            as available.
          '';
        };

        patchTree = mkOption {
          type = types.nullOr (
            types.submodule {
              options = {
                src = mkOption {
                  type = types.path;
                  description = "Source tree holding the crates to patch in.";
                };
                prefix = mkOption {
                  type = types.str;
                  example = "embassy-";
                  description = "Only sub-directories with this prefix are considered.";
                };
              };
            }
          );
          default = null;
          description = ''
            Patch in every crate under a source tree whose directory name starts
            with a prefix and which has a `Cargo.toml`. This picks up crates
            marked `publish = false` that have no crates.io release at all.

            Because the tree is a flake input, `nix flake update <input>` or
            `--override-input <input> ~/my-fork` moves the whole environment onto
            a different tree.
          '';
        };

        gitFetchWithCli = mkOption {
          type = types.bool;
          defaultText = lib.literalMD "true when {option}`patchTree` is set";
          description = ''
            Set `net.git-fetch-with-cli` while re-resolving.

            Worth it whenever the resolution pulls crates from git: cargo's
            bundled libgit2 fails those clones intermittently with
            `SSL error: unknown error; class=Ssl (16)`, and the git CLI uses the
            system CA setup and is reliable.
          '';
        };

        seed = mkOption {
          type = types.package;
          readOnly = true;
          description = "The generated seed workspace.";
        };

        vendorDir = mkOption {
          type = types.package;
          readOnly = true;
          description = "Vendored crates for this mode.";
        };

        cargoConfig = mkOption {
          type = types.package;
          readOnly = true;
          description = "Offline `config.toml` pointing cargo at {option}`vendorDir`.";
        };

        cargoConfigOnline = mkOption {
          type = types.package;
          readOnly = true;
          description = "Patches but no source replacement and no offline flag, for re-resolving.";
        };
      };

      config =
        let
          patchCrates =
            if config.patchTree == null then
              { }
            else
              let
                inherit (config.patchTree) src prefix;
              in
              lib.listToAttrs (
                map (n: lib.nameValuePair n "${src}/${n}") (
                  lib.filter (n: lib.hasPrefix prefix n && builtins.pathExists "${src}/${n}/Cargo.toml") (
                    lib.attrNames (builtins.readDir src)
                  )
                )
              );

          allPatches = patchCrates // config.patch;

          patchSection = lib.optionalString (allPatches != { }) (
            ''

              [patch.crates-io]
            ''
            + lib.concatStrings (lib.mapAttrsToList (n: p: "${n} = { path = \"${p}\" }\n") allPatches)
          );

          offlineSection = ''

            [net]
            offline = true
          '';
        in
        {
          gitFetchWithCli = lib.mkDefault (config.patchTree != null);

          seed = seedLib.mkSeed {
            name = "${shellName}-${name}";
            inherit (config) crates extraManifest edition;
          };

          vendorDir =
            if config.vendorHashFile == null then
              # Every crate named in the lock, fetched from crates.io by the
              # checksums already recorded there -- no extra vendor hash to
              # maintain, and `nix build` is what pulls them into the store.
              pkgs.rustPlatform.importCargoLock { lockFile = config.lockFile; }
            else
              pkgs.rustPlatform.fetchCargoVendor {
                name = "${shellName}-${name}-deps";
                # `src` has to be a directory holding the lock; the seed
                # workspace is exactly that, minus the lock, so pair them.
                src = pkgs.runCommandLocal "${shellName}-${name}-vendor-src" { } ''
                  mkdir -p $out
                  cp -r ${config.seed}/. $out/
                  chmod -R u+w $out
                  cp ${config.lockFile} $out/Cargo.lock
                '';
                hash = import config.vendorHashFile;
              };

          cargoConfig =
            if config.vendorHashFile == null then
              # importCargoLock's own config is not reusable -- it names the
              # vendor directory relatively -- but a crates.io-only lock has no
              # git sources, so the whole file is these few tables.
              pkgs.writeText "${shellName}-${name}-cargo-config.toml" (
                ''
                  [source.crates-io]
                  replace-with = "vendored-sources"

                  [source.vendored-sources]
                  directory = "${config.vendorDir}"
                ''
                + offlineSection
                + patchSection
              )
            else
              # fetchCargoVendor emits a config covering every source it
              # vendored -- registry and git alike -- with an `@vendor@`
              # placeholder for the directory. Consuming that is the whole reason
              # this side needs no hand-written stanzas. The substitution has to
              # happen at build time: reading a derivation's output during
              # evaluation would be import-from-derivation. `--replace-fail` makes
              # a change in that placeholder a loud build error rather than a
              # config that silently points nowhere.
              pkgs.runCommandLocal "${shellName}-${name}-cargo-config.toml" { } ''
                substitute ${config.vendorDir}/.cargo/config.toml $out \
                  --replace-fail '@vendor@' '${config.vendorDir}'
                cat ${pkgs.writeText "extra" (offlineSection + patchSection)} >> $out
              '';

          cargoConfigOnline = pkgs.writeText "${shellName}-${name}-cargo-config-online.toml" (
            lib.optionalString config.gitFetchWithCli ''
              [net]
              git-fetch-with-cli = true
            ''
            + patchSection
          );
        };
    }
  );

  modes = config.modes;
  modeNames = lib.attrNames modes;

  defaultMode =
    if config.defaultMode != null then
      config.defaultMode
    else if modeNames == [ ] then
      throw "offline-devshells: shell `${shellName}' enables the rust backend but declares no `rust.modes'."
    else
      lib.head modeNames;

  # Bash associative-array literals for the generated scripts. One `[k]=v` per
  # line, so a mode name with a space would break -- mode names are cargo-config
  # file names in practice, so this is not worth guarding.
  bashMap =
    f:
    lib.concatStrings (
      lib.mapAttrsToList (n: m: "    [${lib.escapeShellArg n}]=${lib.escapeShellArg (f n m)}\n") modes
    );

  modeCommand = "${commandPrefix}-mode";
  refreshCommand = "${commandPrefix}-refresh-seed";
in
{
  _file = ./default.nix;

  options = {
    version = mkOption {
      type = types.str;
      example = "1.97.1";
      description = ''
        Exact stable Rust version.

        Pinned rather than "latest" on purpose: updating the rust-overlay input
        should not silently swap the compiler out from under a vendored crate set
        that was resolved against a particular MSRV.
      '';
    };

    profile = mkOption {
      type = types.str;
      default = "minimal";
      description = ''
        rust-overlay profile. `minimal` plus explicit {option}`extensions`, rather
        than `default`: the only thing `default` adds is rust-docs, several
        hundred megabytes of offline HTML, and clippy and rustfmt come from the
        extension list either way.
      '';
    };

    extensions = mkOption {
      type = types.listOf types.str;
      default = [
        "rust-src"
        "rust-analyzer"
        "clippy"
        "rustfmt"
      ];
      description = "Toolchain components to install.";
    };

    targets = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "thumbv7em-none-eabihf" ];
      description = ''
        Targets to install `rust-std` for. Add one here and re-run `nix build`
        while online, so the matching standard library lands in the store before
        the network goes away.
      '';
    };

    toolchain = mkOption {
      type = types.package;
      defaultText = lib.literalMD "built from {option}`version`, {option}`profile`, {option}`extensions` and {option}`targets`";
      description = "The toolchain package. Assign one directly to bypass the options above.";
    };

    cc = mkOption {
      type = types.package;
      default = pkgs.stdenv.cc;
      defaultText = lib.literalExpression "pkgs.stdenv.cc";
      description = ''
        C toolchain for cargo's build scripts. Those are host binaries and need a
        linker even when everything else is cross-compiled to a bare-metal
        target.
      '';
    };

    cargoHome = mkOption {
      type = types.str;
      default = "$PWD/.cargo-home";
      description = ''
        `CARGO_HOME` for the environment, as a shell fragment expanded at run
        time.

        Project-local by default: cargo insists on a writable `CARGO_HOME` (it
        takes a lock there), the vendored configuration should not leak into the
        user's global `~/.cargo`, and a chosen mode should survive across shell
        entries.
      '';
    };

    modes = mkOption {
      type = types.attrsOf modeType;
      default = { };
      description = ''
        Independently-resolved crate sets. Each is one self-consistent
        resolution; cargo allows only one replacement for crates.io, so they
        cannot be merged, only switched between with `<prefix>-mode`.

        Locks are resolution-specific, so after switching, a project resolved in
        the other mode needs its `Cargo.lock` deleted and regenerated.
      '';
    };

    defaultMode = mkOption {
      type = types.nullOr types.str;
      default = null;
      defaultText = lib.literalMD "the first mode, alphabetically";
      description = "Mode a fresh `CARGO_HOME` is seeded with.";
    };

    packages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Extra packages contributed to the shell alongside the toolchain.";
    };

    contributions = mkOption {
      type = types.raw;
      readOnly = true;
      internal = true;
      description = "What this backend adds to the generic shell layer.";
    };
  };

  config = {
    toolchain = lib.mkOptionDefault (
      (pkgs.rust-bin or (throw ''
        offline-devshells: shell `${shellName}' uses the rust backend, but `pkgs`
        has no `rust-bin`.

        Add the rust-overlay to the nixpkgs this flake evaluates against:

          perSystem = { system, ... }: {
            _module.args.pkgs = import inputs.nixpkgs {
              inherit system;
              overlays = [ inputs.rust-overlay.overlays.default ];
            };
          };
      '')
      ).stable.${config.version}.${config.profile}.override
        {
          inherit (config) extensions targets;
        }
    );

    contributions = {
      packages = [
        config.toolchain
        # Explicit, even though `mkShell` would supply it implicitly: build
        # scripts are host binaries and need a linker, so a cross-compiled
        # `cargo build` dies with `linker \`cc\` not found` without one. The dev
        # shell gets it either way; the *NixOS module* built from the same
        # `packages` list would not, so a machine installed from this
        # environment could not build at all.
        config.cc
      ]
      ++ config.packages;

      # Every entrypoint here drives cargo, one way or another.
      entrypointRuntimeInputs = [
        config.toolchain
        config.cc
      ];

      env = {
        # The one that matters: the config.toml under it is what replaces
        # crates.io with the vendor directory, so this is the whole offline crate
        # set as far as cargo is concerned.
        CARGO_HOME = config.cargoHome;

        # Redundant with the `[net] offline` in that config, and deliberately so:
        # a project-local `.cargo/config.toml` can override the config, but not
        # the environment. Belt and braces on the one property this environment
        # exists to guarantee.
        CARGO_NET_OFFLINE = "true";

        # rust-analyzer finds this through the sysroot when it is launched from a
        # shell that has the toolchain on PATH, and does not when an editor was
        # started some other way. Naming it costs nothing and removes a class of
        # "goto definition does not work offline".
        RUST_SRC_PATH = "${config.toolchain}/lib/rustlib/src/rust/library";
      };

      # Self-contained on purpose: seeding the mode by calling `<prefix>-mode`
      # would recurse, because that command carries this same preamble.
      preamble = ''
        mkdir -p "$CARGO_HOME"
        if [ ! -e "$CARGO_HOME/config.toml" ]; then
          install -m 0644 ${modes.${defaultMode}.cargoConfig} "$CARGO_HOME/config.toml"
          printf '%s\n' ${lib.escapeShellArg defaultMode} > "$CARGO_HOME/${commandPrefix}-mode"
        fi
      '';

      banner = lib.mkBefore "${shellName} offline devshell -- mode: $(${modeCommand} current)";

      entrypoints = {
        ${modeCommand} = {
          doc = "Switch between the vendored crate sets (${lib.concatStringsSep ", " modeNames})";
          params = [ ''mode="status"'' ];
          file = ./scripts/mode.sh;
          substitutions = {
            inherit commandPrefix;
            modeConfigs = bashMap (_: m: toString m.cargoConfig);
            modeDescriptions = bashMap (n: m: if m.description == "" then n else m.description);
          };
        };

        ${refreshCommand} = {
          doc = "Re-resolve every crate set against crates.io (needs network)";
          params = [ ''root="."'' ];
          file = ./scripts/refresh-seed.sh;

          # This is the bootstrap command, so it must not depend on what it
          # bootstraps. The shared preamble installs a mode's `cargoConfig`,
          # which names its `vendorDir`, which reads its `lockFile` -- the very
          # file this command exists to produce. Attached, the preamble would
          # make `nix run .#<shell>-refresh-seed` fail to *evaluate* in a fresh
          # repository, which is exactly when it is needed. It builds its own
          # throwaway CARGO_HOMEs anyway.
          applyEnv = false;
          runtimeInputs = [
            config.toolchain
            pkgs.git
            pkgs.nix
          ];
          substitutions = {
            inherit commandPrefix;
            shellName = shellName;
            modeList = lib.concatStringsSep " " (map lib.escapeShellArg modeNames);
            modeSeeds = bashMap (_: m: toString m.seed);
            modeLockPaths = bashMap (_: m: m.lockPath);
            modeOnlineConfigs = bashMap (_: m: toString m.cargoConfigOnline);
            modeHashPaths = bashMap (_: m: if m.vendorHashPath == null then "" else m.vendorHashPath);
          };
        };
      };

      bundlePaths = {
        rust-toolchain = config.toolchain;
      }
      // lib.concatMapAttrs (n: m: {
        "vendor-${n}" = m.vendorDir;
        "cargo-config-${n}.toml" = m.cargoConfig;
        "seed-${n}" = m.seed;
      }) modes;

      packageOutputs = {
        toolchain = config.toolchain;
      }
      // lib.concatMapAttrs (n: m: {
        "vendor-${n}" = m.vendorDir;
        "seed-${n}" = m.seed;
      }) modes;
    };
  };
}
