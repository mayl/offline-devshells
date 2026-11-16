# Where the embassy crates' versions come from, so that nothing else has to say.
#
# `crates.nix` names the crates embassy itself publishes (everything that lives
# in the embassy tree: `embassy-*`, `cyw43`, `cyw43-pio`) *without* a version.
# This file fills one in, per mode:
#
#   * git mode: the version in the pinned tree's own `Cargo.toml`. Read at
#     evaluation time, so `nix flake update embassy` -- or `--override-input
#     embassy ~/fork` -- moves every requirement with it, and the `[patch]`
#     table always has a version to satisfy.
#
#     Read with a line match rather than `builtins.fromTOML`: embassy's
#     manifests use TOML 1.1 (multi-line inline tables), which Nix's parser
#     rejects. `version = "..."` under `[package]` is all that is needed here.
#   * crates-io mode: the newest release on crates.io, from `versions.json`.
#     That has to be a file, because finding out needs the network;
#     `embassy-bump` rewrites it. When a release crosses a major (0.x minor),
#     the previous one stays seeded alongside as `<name>-prev`, so projects
#     pinned to it still resolve offline until the next major moves it on.
#
# Requested features the chosen version does not have are dropped rather than
# failing resolution. Which ones those are is recorded in `versions.json` by
# `embassy-bump` for both modes (it asks cargo, which can parse the tree's
# manifests; for a tree you override in yourself, nothing is dropped and cargo
# names any missing feature when you re-resolve). features matter to vendoring only through the optional
# dependencies they gate, and a feature upstream removed usually means "always
# on now" (embassy-nrf's `gpiote`). Every drop is listed in `report`, which
# `embassy-bump` prints and puts in its PR, so a rename that loses a dependency
# does not go unnoticed. A crate that is no longer in the tree at all is not
# something to guess about: that stops evaluation with a message.
#
# Entries that *do* give a version (`embassy-executor-09`, `embassy-nrf-09`) are
# deliberate older majors and are passed through untouched.
{
  lib,
  embassySrc,
  pinned,
}:
let
  # A version's semver compatibility class: what a caret requirement on it
  # accepts. `0.10.2` -> "0.10", `1.4.0` -> "1".
  compat =
    v:
    let
      parts = lib.splitString "." v;
      major = lib.head parts;
    in
    if major != "0" then major else lib.concatStringsSep "." (lib.take 2 parts);

  # Does `version` satisfy the plain caret requirement `req` ("0.10", "0.5.1")?
  # Anything with an operator in it is treated as satisfied: it was written by
  # hand, and is left alone.
  satisfies =
    req: version:
    if builtins.match "[0-9]+(\\.[0-9]+)*" req == null then
      true
    else
      compat req == compat version && builtins.compareVersions req version <= 0;

  treeManifest = name: embassySrc + "/${name}/Cargo.toml";
  inTree = name: builtins.pathExists (treeManifest name);

  # `version = "..."` in the `[package]` table, or null.
  treeVersion =
    name:
    let
      step =
        state: line:
        if state.found != null then
          state
        else if builtins.match "\\[.*" line != null then
          state // { inPackage = line == "[package]"; }
        else
          let
            m = builtins.match "version *= *\"([^\"]+)\".*" line;
          in
          if state.inPackage && m != null then state // { found = lib.head m; } else state;
    in
    (lib.foldl' step {
      inPackage = false;
      found = null;
    } (lib.splitString "\n" (builtins.readFile (treeManifest name)))).found;

  # Crate directories in the pinned tree.
  treeCrates = lib.filter inTree (
    lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir embassySrc))
  );

  normalize = spec: if builtins.isString spec then { version = spec; } else spec;
  crateName = depName: spec: spec.package or depName;
  isDerived = spec: (normalize spec).version or null == null;

  # Per mode: given a crate name, what version it gets and which of the
  # requested features it lacks.
  lookups = {
    git =
      name: requested:
      let
        version = treeVersion name;
        unavailable = pinned.git.${name}.unavailable or [ ];
      in
      if !inTree name then
        throw ''
          offline-devshells (embassy preset): `${name}' is in presets/embassy/crates.nix
          but is no longer in the pinned embassy tree (${toString embassySrc}).

          Upstream removed or renamed it. Decide what replaces it -- check embassy's
          history for the crate's directory -- then remove or rename the entry in
          crates.nix and run the bump again.
        ''
      else if version == null then
        throw "offline-devshells (embassy preset): ${name}'s Cargo.toml in the embassy tree has no literal `version` under [package]."
      else
        {
          inherit version;
          unavailable = lib.filter (f: lib.elem f unavailable) requested;
        };

    crates-io =
      name: requested:
      let
        entry =
          pinned.cratesIo.${name} or (throw ''
            offline-devshells (embassy preset): `${name}' has no entry in
            presets/embassy/versions.json. Run `nix run .#embassy-bump` (with network)
            to look up its newest crates.io release.
          '');
      in
      {
        inherit (entry) version;
        unavailable = lib.filter (f: lib.elem f (entry.unavailable or [ ])) requested;
      };
  };

  # Fill in one mode's crate set. Returns the set and the list of dropped
  # features.
  fill =
    mode: crates:
    let
      lookup = lookups.${mode};
      perDep =
        member: depName: spec':
        let
          spec = normalize spec';
          name = crateName depName spec;
          requested = spec.features or [ ];
          r = lookup name requested;
          filled = spec // {
            inherit (r) version;
            features = lib.filter (f: !lib.elem f r.unavailable) requested;
          };

          # crates-io only: the previous major, if the bump recorded one and no
          # hand-written entry in this member already seeds that major.
          prev = pinned.cratesIo.${name}.previous or null;
          handSeeded = lib.any (
            s:
            let
              n = normalize s;
            in
            !isDerived s && (n.package or null) == name && compat n.version == compat prev.version
          ) (lib.attrValues crates.${member});
          prevDep = lib.optionalAttrs (mode == "crates-io" && prev != null && !handSeeded) {
            "${depName}-prev" = spec // {
              package = name;
              inherit (prev) version;
              features = lib.filter (f: !lib.elem f (prev.unavailable or [ ])) requested;
            };
          };
        in
        if !isDerived spec' then
          {
            deps.${depName} = spec';
            dropped = [ ];
          }
        else
          {
            deps = {
              ${depName} = filled;
            }
            // prevDep;
            dropped = map (feature: {
              inherit
                mode
                member
                feature
                ;
              crate = name;
              inherit (r) version;
            }) r.unavailable;
          };

      results = lib.mapAttrs (member: deps: lib.mapAttrsToList (perDep member) deps) crates;
    in
    {
      crates = lib.mapAttrs (_: rs: lib.foldl' (acc: r: acc // r.deps) { } rs) results;
      dropped = lib.concatMap (rs: lib.concatMap (r: r.dropped) rs) (lib.attrValues results);
    };

  # name -> version, for everything a mode derives. What the example firmwares'
  # and the template's manifests are rewritten against.
  derivedVersions =
    mode: crates:
    lib.foldl' (acc: x: acc // x) { } (
      lib.concatMap (
        deps:
        lib.mapAttrsToList (
          depName: spec:
          lib.optionalAttrs (isDerived spec) {
            ${crateName depName spec} = (lookups.${mode} (crateName depName spec) [ ]).version;
          }
        ) deps
      ) (lib.attrValues crates)
    );

  # Rewrite the version requirements of the named crates in a manifest, line by
  # line, leaving every other byte alone. Handles the two forms our files use,
  # in both TOML and Nix spelling:
  #
  #   name = "0.5.1"                       name = "0.5";
  #   name = { version = "0.10", ... }     name = {  /  version = "0.10";
  #
  # A requirement the new version still satisfies is kept as written, so a
  # routine bump touches only what actually moved. `exact` names are replaced
  # whenever they differ (the template's Rust version).
  rewrite =
    {
      text,
      versions,
      exact ? { },
    }:
    let
      replace =
        name: old:
        if exact ? ${name} then
          exact.${name}
        else if versions ? ${name} && !satisfies old versions.${name} then
          versions.${name}
        else
          old;
      step =
        state: line:
        let
          inline = builtins.match "( *)([A-Za-z0-9_.-]+) = \"([^\"]*)\"(.*)" line;
          table = builtins.match "( *)([A-Za-z0-9_.-]+) = \\{ *version = \"([^\"]*)\"(.*)" line;
          opens = builtins.match " *([A-Za-z0-9_.-]+) = \\{" line;
          versionLine = builtins.match "( *)version = \"([^\"]*)\"(.*)" line;
          closes = builtins.match " *};?" line != null;
          emit = l: state // { out = state.out ++ [ l ]; };
          at = lib.elemAt;
        in
        if table != null then
          emit "${at table 0}${at table 1} = { version = \"${replace (at table 1) (at table 2)}\"${at table 3}"
        else if versionLine != null && state.block != null then
          emit "${at versionLine 0}version = \"${replace state.block (at versionLine 1)}\"${at versionLine 2}"
        else if inline != null then
          emit "${at inline 0}${at inline 1} = \"${replace (at inline 1) (at inline 2)}\"${at inline 3}"
        else if opens != null then
          (emit line) // { block = lib.head opens; }
        else if closes then
          (emit line) // { block = null; }
        else
          emit line;
    in
    lib.concatStringsSep "\n" (
      (lib.foldl' step {
        out = [ ];
        block = null;
      } (lib.splitString "\n" text)).out
    );
in
{
  inherit
    compat
    treeCrates
    rewrite
    isDerived
    crateName
    ;

  # crates.nix's `{ cratesIo, git }`, with every version filled in.
  resolve =
    crates:
    let
      git = fill "git" crates.git;
      cratesIo = fill "crates-io" crates.cratesIo;
    in
    {
      git = git.crates;
      cratesIo = cratesIo.crates;
      dropped = cratesIo.dropped ++ git.dropped;
      droppedGit = git.dropped;
      versions = {
        git = derivedVersions "git" crates.git;
        cratesIo = derivedVersions "crates-io" crates.cratesIo;
      };
    };
}
