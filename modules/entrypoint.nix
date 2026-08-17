# The `offlineShells.<name>.entrypoints.<cmd>` submodule.
#
# An entrypoint is a shell script that ships with the environment: the thing a
# user actually types. It is declared here and *built* in ./shell-submodule.nix,
# because building it needs the shell's env preamble, which is itself assembled
# from every backend's contributions -- reading that from inside this submodule
# would be a module-system cycle.
{ lib }:
{ ... }:
{
  options = {
    file = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Script to run, kept as a real file so it can be shellcheck'd and edited
        normally. Mutually exclusive with {option}`text`.

        The file's own `#!` line and `set -euo pipefail` are harmless: the script
        is wrapped in `writeShellApplication`, which supplies both itself and
        leaves the originals as comments.
      '';
    };

    text = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Script body, for scripts short enough not to want their own file.";
    };

    runtimeInputs = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = ''
        Packages placed on `PATH` for the script, on top of the shell-wide
        {option}`entrypointRuntimeInputs`.
      '';
    };

    runtimeAll = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Put the shell's entire {option}`packages` list and every *other*
        entrypoint on `PATH` for this script.

        For a command whose job is to hand the environment to something else -- a
        shell to work in, a wrapper that runs an arbitrary command inside the
        environment. An ordinary entrypoint should name what it needs instead, so
        that what it depends on stays legible.
      '';
    };

    runtimeEntrypoints = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "embassy-lock" ];
      description = ''
        Other entrypoints of the same shell that this one shells out to, by
        command name.

        Naming them here rather than relying on the ambient `PATH` is what keeps
        a script working when it is invoked from a `just` recipe rather than from
        inside the dev shell. Cycles are not detected -- and would deadlock
        evaluation, not merely misbehave.
      '';
    };

    substitutions = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.str lib.types.path);
      default = { };
      example = lib.literalExpression "{ embassySrc = inputs.embassy; }";
      description = ''
        `@key@` placeholders replaced in the script body. Values are `toString`ed,
        so store paths substitute as themselves and become runtime references of
        the resulting script.

        Beware of interpolating a flake-relative path (`./nix/foo`): that yields a
        subpath of the *whole* flake source, so the script would rebuild on every
        edit to any file in the flake. Copy the content through `writeText`
        instead, and it is keyed on the content alone.
      '';
    };

    applyEnv = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to prepend the shell's {option}`env` and {option}`preamble` to
        this script.

        Turn it off for a command that has to run *before* the environment
        exists. A bootstrap command must not depend on what it bootstraps: the
        preamble typically installs a generated configuration, and generating
        that configuration can require artefacts the bootstrap command is there
        to produce. With the preamble attached, such a command cannot even be
        evaluated until it has already been run once.
      '';
    };

    doc = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        One-line description. Used as the app's `meta.description`, as the
        global-just recipe comment, and in the fish completion.
      '';
    };

    params = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "name"
        "chip"
        "*flags"
      ];
      description = ''
        Parameter names for the generated `just` recipe signature. `just`'s own
        syntax applies, so `*flags` is variadic and `x="d"` has a default.

        Each one is forwarded to the script positionally, in order. Names are
        quoted in the recipe body, except variadic ones -- those must stay
        unquoted to expand to separate words.
      '';
    };

    just = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to expose this entrypoint as a global-just recipe.

          Off by default, because a recipe is only worth having for a command you
          would run from *outside* the environment. Once you are inside it, every
          entrypoint is already on `PATH`, so `jg ns::foo` is a longer way to
          write `foo` -- and a worse one, since `just` runs recipe lines through
          an extra `sh -cu` that will expand a `$VAR` in your arguments before
          the command ever sees it.

          The generated shell entrypoint turns this on for itself, which is the
          case that genuinely needs it: getting in.
        '';
      };

      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        defaultText = lib.literalMD "the command name with the shell's `commandPrefix-` stripped";
        description = ''
          Recipe name inside the shell's namespace, so this entrypoint is run as
          `jg <justNamespace>::<name>`.

          The prefix is stripped by default because the namespace already carries
          it: `embassy-generate` becomes `jg embassy::generate`, not
          `jg embassy::embassy-generate`.
        '';
      };
    };

    app = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to expose this entrypoint as a flake `apps.<cmd>` output.";
    };
  };
}
