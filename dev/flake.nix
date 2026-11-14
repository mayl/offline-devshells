{
  description = "offline-devshells: inputs used only by the embassy appliance and its boot test";

  # Not a flake you use directly. The root flake loads these inputs into its
  # `dev` partition (flake-parts' `partitions`), so a consumer of the modules
  # never locks or fetches them -- they only matter for `nix build
  # .#embassy-box.*` and `nix build .#embassy-box-test`.
  #
  # Flake `follows` cannot reach the root flake's inputs from here, so
  # `dev-nixpkgs` and `dev-flake-parts` exist purely as follow targets that
  # deduplicate this lock. Keep them at the same revisions as the root lock's
  # `nixpkgs` and `flake-parts`: then they are the same store paths and cost
  # nothing. Nothing is *built* from them -- the machine is evaluated against
  # the root flake's `nixpkgs`, which this partition inherits.
  inputs = {
    dev-nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    dev-flake-parts.url = "github:hercules-ci/flake-parts";
    dev-flake-parts.inputs.nixpkgs-lib.follows = "dev-nixpkgs";

    vm-parts.url = "github:mayl/vm-parts";
    vm-parts.inputs.nixpkgs.follows = "dev-nixpkgs";
    vm-parts.inputs.flake-parts.follows = "dev-flake-parts";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "dev-nixpkgs";

    nix-global-just.url = "github:mayl/nix-global-just";
    nix-global-just.inputs.nixpkgs.follows = "dev-nixpkgs";
    nix-global-just.inputs.home-manager.follows = "home-manager";
  };

  outputs = _: { };
}
