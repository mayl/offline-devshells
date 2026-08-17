# The two example firmwares, built from the vendored crate sets.
#
# They exist as `checks`: one per mode, so `nix flake check` proves that both
# resolutions actually compile rather than merely evaluate. Each also lands in
# the offline bundle as a flashable artifact.
{
  pkgs,
  lib,
  toolchain,
  cargoConfigs,
}:
let
  mkFirmware =
    {
      name,
      src,
      target,
      config,
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
        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild
        cargo build --release --locked --offline --target ${target}
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
  };
}
