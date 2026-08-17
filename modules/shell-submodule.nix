# The `offlineShells.<name>` submodule: the language-agnostic half.
#
# It owns everything that is true of *any* offline environment -- what is on
# PATH, what environment the tools run in, which commands the user types, how
# those commands reach the global justfile, and how the whole closure is dragged
# into an image -- and knows nothing about crates, toolchains or registries.
#
# Language support arrives as a *backend*: an option whose value sets a
# `contributions` attrset, which is merged back into the options below. `rust`
# (./rust) is the only one so far. Adding `julia` means writing ./julia, adding
# it to `backendModules` and declaring the matching option -- but nothing about
# how contributions are assembled, or anything downstream of that, changes.
{
  pkgs,
}:
{
  name,
  config,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  backendModules = {
    rust = import ./rust { inherit pkgs lib; };
  };

  # Every backend that was actually configured, as a list of contribution
  # attrsets. Backends set `contributions` on themselves; this is where those
  # land back in the generic layer.
  activeBackends = lib.concatMap (
    backend: lib.optional (config.${backend} != null) config.${backend}.contributions
  ) (lib.attrNames backendModules);

  get = attr: fallback: map (b: b.${attr} or fallback) activeBackends;

  # `outputs` is `types.raw`, so the module system never sees inside it and
  # `mkMerge` would survive as a literal attrset. Backend contributions destined
  # for flake outputs are therefore merged by hand.
  mergeAttrs = lib.foldl' lib.mergeAttrs { };

  # `export K="V"` for the dev shell, where the shell owns the environment
  # outright. Quoted, not because a path with a space is likely, but because the
  # values are shell fragments and an unquoted one silently word-splits.
  envExports = lib.concatStrings (
    lib.mapAttrsToList (k: v: ''
      export ${k}="${v}"
    '') config.env
  );

  # `: "${K:=V}"` for entrypoints, where the environment may already have been
  # set by the dev shell and must not be clobbered. This is what lets one script
  # behave identically under `nix develop` and when invoked bare from a `just`
  # recipe -- see the preamble note in the README.
  envDefaults = lib.concatStrings (
    lib.mapAttrsToList (k: v: ''
      : "''${${k}:=${v}}"
      export ${k}
    '') config.env
  );

  # Prepended to every entrypoint. Must stay self-contained -- calling another
  # entrypoint from here would recurse, since that one carries the same preamble.
  scriptPreamble = ''
    # --- offline-devshells: ${name} preamble ---
    ${envDefaults}${config.preamble}
    # --- end preamble ---
  '';

  mkScript =
    cmd: e:
    let
      body =
        if e.file != null && e.text != null then
          throw "offline-devshells: entrypoints.${cmd} of shell `${name}' sets both `file' and `text'; pick one."
        else if e.file != null then
          builtins.readFile e.file
        else if e.text != null then
          e.text
        else
          throw "offline-devshells: entrypoints.${cmd} of shell `${name}' sets neither `file' nor `text'.";
    in
    pkgs.writeShellApplication {
      name = cmd;
      runtimeInputs =
        config.entrypointRuntimeInputs
        ++ e.runtimeInputs
        ++ map (
          other:
          scripts.${other}
            or (throw "offline-devshells: entrypoints.${cmd} of shell `${name}' lists `${other}' in runtimeEntrypoints, but there is no such entrypoint.")
        ) e.runtimeEntrypoints;
      text =
        lib.optionalString e.applyEnv scriptPreamble
        + builtins.replaceStrings (map (k: "@${k}@") (lib.attrNames e.substitutions)) (map toString (
          lib.attrValues e.substitutions
        )) body;
    };

  scripts = lib.mapAttrs mkScript config.entrypoints;

  # Strip the shell's command prefix: the just namespace already carries it, so
  # `embassy-generate` is `jg embassy::generate`, not `jg embassy::embassy-generate`.
  justName =
    cmd: e:
    if e.just.name != null then e.just.name else lib.removePrefix "${config.commandPrefix}-" cmd;

  justRecipes = lib.mapAttrs' (
    cmd: e:
    lib.nameValuePair (justName cmd e) {
      inherit (e) doc params;
      # One line, so `just` runs it with `sh -c` and no shebang-recipe
      # indentation question arises. Variadic parameters stay unquoted, because
      # the whole point of `*flags` is that it expands to separate words.
      #
      # The `cd` is load-bearing. `just` runs a recipe with the working directory
      # set to the justfile's own directory -- for a *global* justfile that is
      # ~/.config/just, which is both read-only under Home Manager and nowhere
      # near the project. Entrypoints here are all project-relative (a
      # `$PWD/.cargo-home`, a scaffold written into the current directory), so
      # without this they would operate on the config directory.
      body =
        let
          arg =
            p:
            let
              bare = lib.removePrefix "+" (lib.removePrefix "*" p);
              pname = lib.head (lib.splitString "=" bare);
            in
            if lib.hasPrefix "*" p || lib.hasPrefix "+" p then "{{${pname}}}" else ''"{{${pname}}}"'';
        in
        lib.concatStringsSep " " (
          [
            # `@` so `just` does not echo the line first: the user typed
            # `jg embassy::generate blinky rp2040` and does not need to see a
            # store path echoed back at them.
            ''@cd "{{invocation_directory()}}" && exec ${lib.getExe scripts.${cmd}}''
          ]
          ++ map arg e.params
        );
    }
  ) (lib.filterAttrs (_: e: e.just.enable) config.entrypoints);

  # The banner may contain command substitutions (`$(embassy-mode current)`), so
  # the heredoc delimiter is deliberately unquoted. Assembled outside the shell
  # hook's own indented string, where nested indentation stripping would mangle
  # the closing delimiter.
  bannerHook = lib.optionalString (config.banner != "") ''
    cat <<OFFLINE_DEVSHELLS_BANNER
    ${config.banner}
    OFFLINE_DEVSHELLS_BANNER
  '';

  devShell = pkgs.mkShell {
    inherit name;
    packages = config.packages ++ lib.attrValues scripts;
    shellHook = envExports + config.preamble + bannerHook;
  };

  # Symlinking everything into one output makes it all a runtime reference, so
  # `nix build` -- or `nix copy` of the result -- drags the entire offline
  # environment along. The symlinks double as an index into the bundle.
  bundle =
    (pkgs.linkFarm "${name}-offline-bundle" (
      config.bundlePaths
      // scripts
      // {
        # Not a tool: realising this pulls in every build input of the dev shell,
        # which is what makes `nix develop` work on a machine that only ever
        # received this closure.
        devshell-inputs = devShell.inputDerivation;
      }
    )).overrideAttrs
      (_: {
        meta.description = "Everything needed to develop with `${name}` and no network";
      });
in
{
  _file = ./shell-submodule.nix;

  options = {
    packages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        Packages on `PATH`, both in the dev shell and in
        {option}`environment.systemPackages` of the generated NixOS module.

        Backends add their own (the Rust toolchain, say); this is for whatever
        else the environment needs.
      '';
    };

    env = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = lib.literalExpression ''{ CARGO_HOME = "\$PWD/.cargo-home"; }'';
      description = ''
        Environment variables for the environment. Values are shell fragments,
        expanded at run time rather than at evaluation time, so `$PWD` means the
        directory the user is in.

        Exported outright by the dev shell, and applied with `:=` defaults by
        every entrypoint, so an entrypoint invoked outside the shell lands in the
        same environment as one invoked inside it.
      '';
    };

    preamble = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Shell run after {option}`env` is applied, both by the dev shell's hook and
        at the top of every entrypoint. For state that has to exist before any
        tool runs -- creating a cache directory, seeding a config file.

        Must be self-contained: calling an entrypoint from here would recurse,
        because that entrypoint carries this same preamble.
      '';
    };

    banner = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Printed on entry to the dev shell, after {option}`preamble` has run.
        Command substitutions are evaluated, so `$(embassy-mode current)` reports
        live state.
      '';
    };

    entrypointRuntimeInputs = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        Packages on `PATH` for *every* entrypoint.

        For the tool the environment is built around -- backends contribute their
        compiler here -- so that each script does not have to name it. Note that
        this is not the same list as {option}`packages`: that one is what the
        *user* gets, this one is what the scripts get, and a script must not
        depend on the user's PATH.
      '';
    };

    entrypoints = mkOption {
      type = types.attrsOf (types.submodule (import ./entrypoint.nix { inherit lib; }));
      default = { };
      description = ''
        The commands this environment provides. Each becomes a package in the dev
        shell, a `packages.<shell>-<cmd>` flake output, an `apps.<cmd>`, an entry
        in the offline bundle, and a recipe in the global justfile.
      '';
    };

    bundlePaths = mkOption {
      type = types.attrsOf types.raw;
      default = { };
      description = ''
        Extra store paths folded into the offline bundle, keyed by the symlink
        name they get inside it.

        Things that are *needed offline* but are not packages on `PATH` belong
        here -- vendored dependency directories, pinned source trees, generated
        configuration. Entrypoints and the dev shell's build inputs are added
        automatically.
      '';
    };

    commandPrefix = mkOption {
      type = types.str;
      default = name;
      description = ''
        Prefix that backend-generated command names carry, and that is stripped
        from an entrypoint's name to form its `just` recipe name.
      '';
    };

    justNamespace = mkOption {
      type = types.str;
      default = name;
      description = "Namespace the entrypoints appear under, as `jg <namespace>::<recipe>`.";
    };

    rust = mkOption {
      type = types.nullOr (
        types.submoduleWith {
          modules = [ backendModules.rust ];
          specialArgs = {
            shellName = name;
            inherit (config) commandPrefix;
          };
        }
      );
      default = null;
      description = ''
        Rust backend: a pinned toolchain plus one or more vendored,
        independently-resolved crate sets. See `modules/rust/default.nix`.
      '';
    };

    devShell = mkOption {
      type = types.package;
      readOnly = true;
      description = "The dev shell, exposed as `devShells.<name>`.";
    };

    bundle = mkOption {
      type = types.package;
      readOnly = true;
      description = ''
        A `linkFarm` of every store path this environment needs offline. Building
        it is what puts the environment in the store; copying it is what moves the
        environment to another machine.
      '';
    };

    scripts = mkOption {
      type = types.attrsOf types.package;
      readOnly = true;
      description = "Built entrypoints, keyed by command name.";
    };

    justRecipes = mkOption {
      type = types.attrsOf types.raw;
      readOnly = true;
      description = "The `programs.globalJust.recipes.<namespace>` attrset this shell generates.";
    };

    homeModule = mkOption {
      type = types.raw;
      readOnly = true;
      description = ''
        Home Manager module putting the entrypoints in the global justfile.

        Import `nix-global-just`'s own `homeManagerModules.default` alongside it:
        this module only *defines* `programs.globalJust` options, it does not
        declare them.
      '';
    };

    nixosModule = mkOption {
      type = types.raw;
      readOnly = true;
      description = ''
        NixOS module installing the environment system-wide: every package and
        entrypoint on `PATH`, plus the whole offline bundle pinned into the
        system closure.

        Note what this does and does not give you. The commands work directly,
        with no shell to enter -- that is the point. It does *not* make
        `nix develop` work on the resulting machine: the closure is there, but
        the flake and its locked inputs are not, so there is nothing to evaluate.
        Ship those separately if you want that route.
      '';
    };

    outputs = mkOption {
      type = types.raw;
      readOnly = true;
      internal = true;
      description = "Flake outputs contributed by this shell, collected in ./offline-shells.nix.";
    };
  };

  config = {
    packages = lib.mkMerge (get "packages" [ ]);
    entrypointRuntimeInputs = lib.mkMerge (get "entrypointRuntimeInputs" [ ]);
    env = lib.mkMerge (get "env" { });
    preamble = lib.mkMerge (get "preamble" "");
    banner = lib.mkMerge (get "banner" "");
    entrypoints = lib.mkMerge (get "entrypoints" { });
    bundlePaths = lib.mkMerge (get "bundlePaths" { });

    inherit
      devShell
      bundle
      scripts
      justRecipes
      ;

    homeModule = {
      _file = "${toString ./shell-submodule.nix} (offlineShells.${name}.homeModule)";
      programs.globalJust = {
        enable = lib.mkDefault true;
        recipes.${config.justNamespace} = justRecipes;
      };
    };

    nixosModule = {
      _file = "${toString ./shell-submodule.nix} (offlineShells.${name}.nixosModule)";
      environment.systemPackages = config.packages ++ lib.attrValues scripts;
      # Not `systemPackages`: the bundle is a bag of symlinks, not something to
      # put on PATH. `extraDependencies` is exactly the "keep this in the image's
      # store, referenced by nothing" hook.
      #
      # Most of the bundle is already reachable from the entrypoints above -- a
      # vendor directory is a reference of a cargo config, which is a reference of
      # the mode script. This pins the rest: `bundlePaths` entries nothing happens
      # to mention, and the dev shell's own build inputs. So "the environment is
      # complete on this machine" stays true even when an entrypoint stops
      # referring to some piece of it.
      system.extraDependencies = [ bundle ];
    };

    outputs = {
      devShells.${name} = devShell;

      packages =
        # `packages.<shell>` is the bundle, because building the shell by name is
        # what a user means by "put this environment in my store".
        {
          ${name} = bundle;
        }
        # Entrypoint names usually already carry the shell's prefix, so
        # `embassy-generate` stays `packages.embassy-generate` rather than
        # becoming `packages.embassy-embassy-generate`.
        // lib.mapAttrs' (
          cmd: lib.nameValuePair (if lib.hasPrefix "${name}-" cmd then cmd else "${name}-${cmd}")
        ) scripts
        // lib.mapAttrs' (k: lib.nameValuePair "${name}-${k}") (mergeAttrs (get "packageOutputs" { }));

      apps = lib.mapAttrs (cmd: e: {
        type = "app";
        program = lib.getExe scripts.${cmd};
        meta = lib.optionalAttrs (e.doc != null) { description = e.doc; };
      }) (lib.filterAttrs (_: e: e.app) config.entrypoints);

      checks = mergeAttrs (get "checks" { });
    };
  };
}
