# The flake-parts module: `perSystem.offlineShells.<name>` in, flake outputs out.
#
# Per-system rather than top-level because an offline environment *is* a set of
# store paths for one system: a toolchain, a vendor directory, a bundle. The
# NixOS and Home Manager modules a shell exposes are per-system for the same
# reason, and are reached from the top level with flake-parts' `withSystem`.
{ lib, flake-parts-lib, ... }:
{
  _file = ./offline-shells.nix;
  _class = "flake";

  # Deliberate key, so the module is deduplicated no matter which path it is
  # reached by (the flake's store path differs between consumers).
  key = "offline-devshells/offline-shells.nix";

  options.perSystem = flake-parts-lib.mkPerSystemOption (
    { config, pkgs, ... }:
    let
      shells = lib.attrValues config.offlineShells;
      collect = attr: lib.foldl' (acc: s: acc // s.outputs.${attr} or { }) { } shells;
    in
    {
      _file = ./offline-shells.nix;

      options.offlineShells = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submoduleWith {
            modules = [ (import ./shell-submodule.nix { inherit pkgs; }) ];
          }
        );
        default = { };
        example = lib.literalExpression ''
          {
            embassy = {
              packages = [ pkgs.probe-rs-tools ];
              rust = {
                version = "1.97.1";
                targets = [ "thumbv7em-none-eabi" ];
                modes.crates-io = {
                  crates.common.heapless = { version = "0.9"; features = [ "serde" ]; };
                  lockFile = ./locks/crates-io.lock;
                  lockPath = "locks/crates-io.lock";
                };
              };
            };
          }
        '';
        description = ''
          Development environments whose entire dependency set is realised into
          the Nix store, so they keep working with the network unplugged.

          Each shell `s` becomes `devShells.s`, `packages.s` (its offline
          bundle), one `packages.s-<cmd>` and `apps.<cmd>` per entrypoint, and
          carries `nixosModule` / `homeModule` for putting it in an image.
        '';
      };

      config = {
        devShells = collect "devShells";
        packages = collect "packages";
        apps = collect "apps";
        checks = collect "checks";
      };
    }
  );
}
