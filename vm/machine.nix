# The offline embedded-Rust box.
#
# An ordinary NixOS module: bootloader, filesystems and partitioning come from
# whichever vm-parts format is being built, which is what lets one configuration
# become both a qemu run script and a VirtualBox appliance.
#
# The environment itself is not described here. It arrives as
# `offlineShells.embassy.nixosModule` (packages, and the offline bundle pinned
# into the system closure) and `offlineShells.embassy.homeModule` (the global
# justfile), both wired up in ../flake.nix.
{
  lib,
  pkgs,
  ...
}:
let
  user = "larry";
in
{
  networking.hostName = "embassy";

  users.users.${user} = {
    isNormalUser = true;
    description = "Embedded Rust";
    # `dialout` for USB serial adapters, `plugdev` for the udev rules below.
    extraGroups = [
      "wheel"
      "dialout"
      "plugdev"
    ];
    initialPassword = "embassy";
    shell = pkgs.fish;
  };

  users.groups.plugdev = { };
  users.users.root.initialPassword = "embassy";

  # nix-global-just installs its `jg` completion as a fish completion and its
  # alias as a fish function, so fish is not optional here.
  programs.fish.enable = true;

  security.sudo.wheelNeedsPassword = false;
  services.openssh.enable = true;

  # Debug probes: without these the probe shows up root-only and `cargo run`
  # fails with a permissions error that reads like a missing probe.
  #
  # Written out here rather than taken from `services.udev.packages`, because
  # nixpkgs' `probe-rs-tools` output is three binaries and nothing else -- it
  # ships no `lib/udev/rules.d`.
  services.udev.extraRules = ''
    # probe-rs: CMSIS-DAP v1 (HID) and v2 (WinUSB/bulk).
    SUBSYSTEM=="hidraw", ATTRS{interface}=="*CMSIS-DAP*", MODE="660", GROUP="plugdev", TAG+="uaccess"
    SUBSYSTEM=="usb", ATTRS{interface}=="*CMSIS-DAP*", MODE="660", GROUP="plugdev", TAG+="uaccess"
    # ST-Link v2 / v2.1 / v3
    SUBSYSTEM=="usb", ATTR{idVendor}=="0483", ATTR{idProduct}=="374[0-9b-f]", MODE="660", GROUP="plugdev", TAG+="uaccess"
    SUBSYSTEM=="usb", ATTR{idVendor}=="0483", ATTR{idProduct}=="3748", MODE="660", GROUP="plugdev", TAG+="uaccess"
    # SEGGER J-Link
    SUBSYSTEM=="usb", ATTR{idVendor}=="1366", MODE="660", GROUP="plugdev", TAG+="uaccess"
    # Raspberry Pi Debug Probe / picoprobe, and RP2040 in BOOTSEL
    SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", MODE="660", GROUP="plugdev", TAG+="uaccess"
    # FTDI-based probes
    SUBSYSTEM=="usb", ATTR{idVendor}=="0403", MODE="660", GROUP="plugdev", TAG+="uaccess"
    # TI XDS110 (MSPM0 LaunchPads)
    SUBSYSTEM=="usb", ATTR{idVendor}=="0451", MODE="660", GROUP="plugdev", TAG+="uaccess"
  '';

  # Guest additions are deliberately NOT enabled here; see the `mkForce false`
  # and its reasoning in ../flake.nix. Note that USB passthrough of a debug probe
  # does not depend on them -- that is arranged host-side, by a VirtualBox USB
  # filter plus the Extension Pack.

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # This machine is meant to run with the network unplugged. An empty
    # substituter list turns "quietly hang trying to reach cache.nixos.org" into
    # an immediate, legible failure -- and everything that should be here is in
    # the image already.
    substituters = lib.mkForce [ ];
    trusted-public-keys = lib.mkForce [ ];
  };

  # Nothing here can be rebuilt from source offline anyway, and the channel is
  # only a way to end up with a second, stale nixpkgs on disk.
  nix.channel.enable = false;

  # ~250 MB of manpages and HTML that the offline crate docs do not need.
  documentation.nixos.enable = false;

  environment.systemPackages = with pkgs; [
    git
    helix
    ripgrep
    fd
    usbutils
    minicom
  ];

  time.timeZone = lib.mkDefault "UTC";
  console.keyMap = lib.mkDefault "us";

  # VirtualBox sizing lives in ../flake.nix, under
  # `vms.embassy-box.formatModules.virtualbox`: the `virtualbox.*` options are
  # declared by that format's module, so setting them here would break every
  # other format this machine builds.

  system.stateVersion = "25.11";
}
