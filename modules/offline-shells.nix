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
      shells = config.offlineShells;

      # Gather one output attribute across every shell.
      #
      # `apps` is the one place where two shells can genuinely collide: entrypoint
      # names are not prefixed there, because `nix run .#embassy-generate` reading
      # as itself is the point. A silent `//` would let one shell's app shadow
      # another's, so say so instead. `packages` cannot collide -- every name is
      # prefixed with the shell's -- and `devShells` are keyed by shell name.
      collect =
        attr:
        let
          perShell = lib.mapAttrs (_: s: s.outputs.${attr} or { }) shells;
          seen = lib.zipAttrsWith (_: owners: owners) (
            lib.mapAttrsToList (shellName: outs: lib.mapAttrs (_: _: shellName) outs) perShell
          );
          clashes = lib.filterAttrs (_: owners: lib.length owners > 1) seen;
        in
        if clashes == { } then
          lib.foldl' lib.mergeAttrs { } (lib.attrValues perShell)
        else
          throw ''
            offline-devshells: two shells contribute the same `${attr}' output.

            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (
                n: owners: "  ${attr}.${n} -- from ${lib.concatStringsSep " and " owners}"
              ) clashes
            )}

            Rename the entrypoint, or set `entrypoints.<cmd>.app = false` on all
            but one of them.
          '';
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
