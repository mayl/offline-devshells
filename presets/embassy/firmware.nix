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
{
  pkgs,
  lib,
  toolchain,
  cargoConfigs,
  gitSeedLock,
}:
let
  mkFirmware =
    {
      name,
      src,
      target,
      config,
      seedLock ? null,
    }:
    pkgs.stdenv.mkDerivation {
      pname = name;
      version = "0.1.0";
      inherit src;

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
  # STM32F411CE, built from the published crates.
  blinky = mkFirmware {
    name = "blinky";
    src = ./firmware;
    target = "thumbv7em-none-eabi";
    config = cargoConfigs.crates-io;
  };

  # MSPM0G3507, built from the embassy git tree -- there is no other way to
  # build it, and it doubles as the proof that git mode works.
  blinkyMspm0 = mkFirmware {
    name = "blinky-mspm0";
    src = ./firmware-mspm0;
    target = "thumbv6m-none-eabi";
    config = cargoConfigs.git;
    seedLock = gitSeedLock;
  };
}
