# offline-devshells: the flake-parts module.
#
# Import this into your flake-parts flake:
#
#   imports = [ inputs.offline-devshells.flakeModules.default ];
#
#   perSystem = { pkgs, ... }: {
#     offlineShells.myEnv = {
#       packages = [ pkgs.probe-rs-tools ];
#       rust = {
#         version = "1.97.1";
#         targets = [ "thumbv7em-none-eabi" ];
#         modes.crates-io = {
#           crates.common.heapless = { version = "0.9"; features = [ "serde" ]; };
#           lockFile = ./locks/crates-io.lock;
#           lockPath = "locks/crates-io.lock";
#         };
#       };
#     };
#   };
#
# and then `nix build .#myEnv` to realise the whole environment into the store.
#
# For a ready-made Embassy environment, import `flakeModules.embassy` instead --
# it is nothing but the above, filled in.
{
  _class = "flake";
  imports = [ ./modules/offline-shells.nix ];
}
