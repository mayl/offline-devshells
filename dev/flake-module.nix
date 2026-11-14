# The `dev` partition: the embassy appliance and its boot test.
#
# Evaluated as a re-run of the root flake's modules plus this one, with the
# inputs of ./flake.nix added -- so the embassy environment here is the very
# same one `nix build .#embassy` produces, built from the root `nixpkgs`, while
# vm-parts, Home Manager and nix-global-just stay out of every consumer's lock.
{
  inputs,
  config,
  withSystem,
  ...
}:
{
  imports = [ inputs.vm-parts.flakeModules.default ];

  # The offline embedded-Rust box. Its environment comes from the embassy
  # preset; ../vm/machine.nix describes only the machine.
  vms.embassy-box = {
    system = "x86_64-linux";
    modules = [
      ../vm/machine.nix
      inputs.home-manager.nixosModules.home-manager
      (withSystem "x86_64-linux" (
        { config, ... }:
        {
          imports = [ config.offlineShells.embassy.nixosModule ];

          home-manager.users.larry = {
            imports = [
              inputs.nix-global-just.homeManagerModules.default
              # Only *defines* programs.globalJust options; the module
              # declaring them is the import above.
              config.offlineShells.embassy.homeModule
            ];
            home.stateVersion = "25.11";

            # nix-global-just only writes its fish function (`jg`) and
            # completions when Home Manager's fish is on -- the system-wide
            # `programs.fish.enable` in machine.nix is not enough.
            programs.fish.enable = true;
          };
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
        }
      ))
    ];

    # Merged into the built-in `virtualbox` format rather than replacing
    # it, which is why the sizing can live here instead of in machine.nix.
    formatModules.virtualbox =
      { lib, ... }:
      {
        virtualbox.memorySize = 4096;
        virtualbox.params.cpus = 4;
        virtualbox.vmName = "embassy-offline";
        image.baseName = "embassy-offline";

        # nixpkgs' virtualbox-image.nix turns guest additions on
        # unconditionally -- not `mkDefault` -- and as of the pinned
        # nixpkgs the 7.2.14 additions do not compile against any kernel in
        # the tree: `vbox_fb.c` still calls `drm_fb_helper_alloc_info`
        # through a declaration the kernel no longer provides, so the build
        # dies with `-Wint-conversion`. Hence `mkForce` rather than a
        # polite override.
        #
        # What that costs: shared folders (vboxsf), clipboard sharing and
        # guest time sync. What it does not cost: USB passthrough of a debug
        # probe, which is a host-side VirtualBox feature. Move code in and
        # out over SSH instead -- `services.openssh` is on.
        #
        # Re-check on every nixpkgs bump, and drop this once the additions
        # build again.
        virtualisation.virtualbox.guest.enable = lib.mkForce false;
      };

    formats = [
      "vbox" # nix build .#embassy-box.vbox.file  -> the .ova
      "vm" # nix build .#embassy-box.vm         -> a qemu run script
    ];
  };

  perSystem =
    {
      pkgs,
      lib,
      system,
      ...
    }:
    {
      # Outside `checks` on purpose: booting it means materialising the whole
      # offline closure into a disk image, which `nix flake check` has no
      # business doing. `legacyPackages` rather than `packages` so it can live
      # in this partition without taking `packages` with it; `nix build
      # .#embassy-box-test` finds it there all the same.
      legacyPackages = lib.optionalAttrs (system == "x86_64-linux") {
        # The same modules the appliance is built from, so the test boots the
        # configuration the appliance ships.
        embassy-box-test = import ../vm/test.nix {
          inherit pkgs;
          inherit (config.vms.embassy-box) modules;
        };
      };
    };
}
