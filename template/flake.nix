{
  description = "An offline Rust environment, and a machine to put it in";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    offline-devshells.url = "github:mayl/offline-devshells";
    offline-devshells.inputs.nixpkgs.follows = "nixpkgs";
    offline-devshells.inputs.flake-parts.follows = "flake-parts";
    offline-devshells.inputs.rust-overlay.follows = "rust-overlay";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.offline-devshells.flakeModules.default ];

      systems = [ "x86_64-linux" ];

      perSystem =
        { system, pkgs, ... }:
        {
          # The rust backend needs `pkgs.rust-bin`.
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.rust-overlay.overlays.default ];
          };

          offlineShells.myEnv = {
            packages = [ pkgs.probe-rs-tools ];

            rust = {
              version = "1.97.1";
              targets = [ "thumbv7em-none-eabihf" ];

              modes.crates-io = {
                description = "published releases";

                # Widen the offline crate set by adding attributes here, then
                # run `nix run .#myEnv-refresh-seed` with network and commit the
                # updated lock. Members are just resolution groups -- put crates
                # that could never be built together in different ones.
                crates.common = {
                  cortex-m = {
                    version = "0.7";
                    features = [ "critical-section-single-core" ];
                  };
                  cortex-m-rt = "0.7";
                  embassy-executor = {
                    version = "0.10";
                    features = [
                      "platform-cortex-m"
                      "executor-thread"
                    ];
                  };
                  embassy-time = "0.5";
                  defmt = "1";
                  defmt-rtt = "1";
                  panic-probe = {
                    version = "1";
                    features = [ "print-defmt" ];
                  };
                };

                # `lockFile` is read; `lockPath` is where refresh-seed writes.
                # They differ because by the time anything can read the lock it
                # is a store path, and store paths are not writable.
                lockFile = ./locks/crates-io.lock;
                lockPath = "locks/crates-io.lock";
              };
            };
          };
        };
    };
}
