# The two example firmwares, built from the vendored crate sets.
#
# They exist as `checks`: one per mode, so `nix flake check` proves that both
# resolutions actually compile rather than merely evaluate. Each also lands in
# the offline bundle as a flashable artifact.
#
# Neither commits a Cargo.lock. Each resolves one at build time exactly the way
# `embassy-lock` does for a user's project -- `cargo generate-lockfile
# --offline` against the vendor directory in crates-io mode, the git-mode seed
# lock (pruned by the build) in git mode -- so the checks exercise the path a
# user takes, and a refreshed crate set needs no second lock bumped by hand.
#
# Nor are their embassy versions kept by hand: each `Cargo.toml` is built with
# its embassy requirements rewritten to the versions the preset derives for that
# mode (./versions.nix), so a firmware always builds against the crate set it is
# meant to prove -- including under `--override-input embassy`. `embassy-bump`
# writes the rewritten manifests back, and this repository's
# `embassy-manifests-in-sync` check refuses a checked-in copy that has drifted.
{
  pkgs,
  lib,
  toolchain,
  cargoConfigs,
  gitSeedLock,
  versions,
  derivedVersions,
}:
let
  # A firmware's manifest with its embassy requirements moved to what the
  # preset derives for `mode`.
  manifest =
    dir: mode:
    versions.rewrite {
      text = builtins.readFile (dir + "/Cargo.toml");
      versions = derivedVersions.${mode};
    };

  mkFirmware =
    {
      name,
      dir,
      mode,
      target,
      config,
      seedLock ? null,
    }:
    pkgs.stdenv.mkDerivation {
      pname = name;
      version = "0.1.0";

      src = pkgs.runCommandLocal "${name}-src" { } ''
        cp -r ${dir} $out
        chmod -R u+w $out
        cp ${pkgs.writeText "${name}-Cargo.toml" (manifest dir mode)} $out/Cargo.toml
      '';

      nativeBuildInputs = [
        toolchain
        pkgs.cargo-binutils
      ];

      # cargo insists on a writable CARGO_HOME (it takes a lock there), so the
      # store config is copied into a scratch dir.
      configurePhase = ''
        runHook preConfigure
        export CARGO_HOME="$(mktemp -d)"
        install -m 0644 ${config} "$CARGO_HOME/config.toml"
        ${
          if seedLock == null then
            "cargo generate-lockfile --offline"
          else
            # A vendored git source cannot be resolved from scratch; see
            # scripts/embassy-lock.sh.
            "install -m 0644 ${seedLock} Cargo.lock"
        }
        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild
        cargo build --release --offline --target ${target}
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        elf=target/${target}/release/${name}
        mkdir -p $out/bin
        cp "$elf" $out/bin/${name}.elf
        # rust-objcopy/rust-size dispatch to the llvm-tools already in the rustc
        # sysroot, so no separate LLVM (~740 MB) is needed.
        rust-objcopy -O binary "$elf" $out/bin/${name}.bin
        rust-objcopy -O ihex "$elf" $out/bin/${name}.hex
        rust-size "$elf" > $out/bin/${name}.size
        runHook postInstall
      '';

      dontFixup = true;

      meta = {
        description = "Example Embassy firmware (${name})";
        platforms = lib.platforms.all;
      };
    };
in
{
  # What each checked-in manifest should say, by path relative to this
  # directory: for `embassy-bump` to write, and the in-sync check to compare.
  manifests = {
    "firmware/Cargo.toml" = manifest ./firmware "cratesIo";
    "firmware-mspm0/Cargo.toml" = manifest ./firmware-mspm0 "git";
  };

  # STM32F411CE, built from the published crates.
  blinky = mkFirmware {
    name = "blinky";
    dir = ./firmware;
    mode = "cratesIo";
    target = "thumbv7em-none-eabi";
    config = cargoConfigs.crates-io;
  };

  # MSPM0G3507, built from the embassy git tree -- there is no other way to
  # build it, and it doubles as the proof that git mode works.
  blinkyMspm0 = mkFirmware {
    name = "blinky-mspm0";
    dir = ./firmware-mspm0;
    mode = "git";
    target = "thumbv6m-none-eabi";
    config = cargoConfigs.git;
    seedLock = gitSeedLock;
  };
}
