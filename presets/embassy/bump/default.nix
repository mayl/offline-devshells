# `embassy-bump`: move the embassy preset to current embassy main, in one command.
#
# This repository's own maintenance tool, wired up in ../../../flake.nix -- not
# part of the preset a consumer imports (a consumer's flake has no `embassy`
# input to move). A human and the weekly workflow run exactly the same thing:
#
#     nix run .#embassy-bump
#
# The script (./embassy-bump.sh) re-evaluates this flake after each step that
# changes its inputs, so everything it asks Nix lives in `passthru.info` below,
# read with `nix eval .#packages.<system>.embassy-bump.info.<attr>`.
{
  pkgs,
  lib,
  inputs,
}:
let
  presetDir = ./..;
  repoRoot = ../../..;

  pinned = lib.importJSON (presetDir + "/versions.json");
  versions = import (presetDir + "/versions.nix") {
    inherit lib pinned;
    embassySrc = inputs.embassy;
  };
  raw = import (presetDir + "/crates.nix") { inherit lib; };
  resolved = versions.resolve raw;

  # Only `manifests` is read, which needs none of the build inputs.
  firmware = import (presetDir + "/firmware.nix") {
    inherit pkgs lib versions;
    derivedVersions = resolved.versions;
    toolchain = null;
    cargoConfigs = { };
    gitSeedLock = null;
  };

  # Every file the bump may rewrite, relative to the repository root, with what
  # it should contain where that is computable here. The script snapshots all
  # of them first and puts them all back if anything fails.
  synced = {
    "presets/embassy/firmware/Cargo.toml" = firmware.manifests."firmware/Cargo.toml";
    "presets/embassy/firmware-mspm0/Cargo.toml" = firmware.manifests."firmware-mspm0/Cargo.toml";
    # The template is a flake of its own, so it cannot read any of this; its
    # versions are rewritten instead. crates-io mode, like the template.
    "template/flake.nix" = versions.rewrite {
      text = builtins.readFile (repoRoot + "/template/flake.nix");
      versions = resolved.versions.cratesIo;
      exact.rust = pinned.rust;
    };
  };

  managedFiles = [
    "flake.lock"
    "presets/embassy/versions.json"
    "presets/embassy/locks/crates-io.lock"
    "presets/embassy/locks/git.lock"
    "presets/embassy/locks/git-vendor-hash.nix"
  ]
  ++ lib.attrNames synced;

  # A mode's derived crates, and the union of the features asked of each: what
  # to look up. Read from crates.nix alone, so it evaluates before
  # versions.json knows about a crate.
  requests =
    crates:
    lib.foldl' (
      acc: deps:
      lib.foldl' (
        acc: depName:
        let
          spec = deps.${depName};
          name = versions.crateName depName spec;
        in
        if versions.isDerived spec then
          acc // { ${name} = lib.unique ((acc.${name} or [ ]) ++ (spec.features or [ ])); }
        else
          acc
      ) acc (lib.attrNames deps)
    ) { } (lib.attrValues crates);

  # Every crate the preset derives, in either mode.
  derivedNames = lib.attrNames (resolved.versions.git // resolved.versions.cratesIo);

  toolchainFile = "${inputs.embassy}/rust-toolchain.toml";
in
{
  inherit synced;

  # The repository refuses checked-in manifests that differ from what the
  # pinned inputs say they should be. Evaluation-time, so `nix flake check
  # --no-build` -- the cheap CI job -- catches it.
  inSync =
    let
      stale = lib.filter (f: builtins.readFile (repoRoot + "/${f}") != synced.${f}) (
        lib.attrNames synced
      );
    in
    if stale == [ ] then
      pkgs.runCommandLocal "embassy-manifests-in-sync" { } "touch $out"
    else
      throw ''
        offline-devshells: these files disagree with the versions the embassy preset
        derives (presets/embassy/versions.nix):
        ${lib.concatMapStrings (f: "  ${f}\n") stale}
        Run `nix run .#embassy-bump` to bring everything forward together, or put
        back the hand edit that caused this.
      '';

  package =
    (pkgs.writeShellApplication {
      name = "embassy-bump";
      # Backticks in single quotes are Markdown and jq, not unexpanded shell.
      excludeShellChecks = [ "SC2016" ];
      runtimeInputs = [
        pkgs.jq
        pkgs.curl
        pkgs.coreutils
        pkgs.diffutils
        pkgs.gnugrep
        pkgs.findutils
        # Only to read the embassy tree's manifests (`cargo metadata --no-deps`),
        # which Nix cannot parse.
        pkgs.cargo
      ];
      # `nix` is deliberately the caller's own, as for refresh-seed.
      text = builtins.replaceStrings [ "@system@" ] [ pkgs.stdenv.hostPlatform.system ] (
        builtins.readFile ./embassy-bump.sh
      );
    }).overrideAttrs
      (old: {
        passthru = (old.passthru or { }) // {
          info = {
            inherit managedFiles derivedNames;
            inherit (versions) treeCrates;
            cratesIoRequests = requests raw.cratesIo;
            gitRequests = requests raw.git;
            embassySrc = "${inputs.embassy}";
            rust = pinned.rust;

            # The channel embassy's own CI builds with, if it names a version.
            embassyChannel =
              if builtins.pathExists toolchainFile then
                (builtins.fromTOML (builtins.readFile toolchainFile)).toolchain.channel or null
              else
                null;

            # Stable versions the rust-overlay this flake pins can provide.
            rustAvailable = lib.filter (v: builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" v != null) (
              lib.attrNames pkgs.rust-bin.stable
            );

            # Forces git mode's derivation: a crate removed from the tree stops
            # here, before anything is resolved.
            gitCheck = builtins.deepSeq resolved.git resolved.droppedGit;

            report = { inherit (resolved) dropped; };
          };

          # The rewritten manifests, as a directory tree to copy over the repo.
          synced = pkgs.runCommandLocal "embassy-bump-synced" { } (
            lib.concatStrings (
              lib.mapAttrsToList (f: text: ''
                mkdir -p "$out/$(dirname ${lib.escapeShellArg f})"
                cp ${pkgs.writeText "synced" text} "$out/"${lib.escapeShellArg f}
              '') synced
            )
          );
        };
      });
}
