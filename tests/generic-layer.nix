# The generic layer on its own, with no backend at all.
#
# Everything else in this repository exercises `offlineShells` through the rust
# backend, which makes it easy for the seam between the two to rot unnoticed --
# a generic option that quietly only works because rust happens to set it. This
# builds a shell that declares no backend and asserts the parts that must hold
# regardless.
#
# Split deliberately: what can be decided from the option values is asserted
# during evaluation, and what needs the *built* scripts is grepped at build time.
# Reading a built script during evaluation would be import-from-derivation, and
# `lib.hasInfix` cannot take a store path in its pattern anyway -- it compiles the
# needle into a regex, and a regex may not carry string context.
{ pkgs, lib }:
let
  shell =
    (lib.evalModules {
      modules = [
        (import ../modules/shell-submodule.nix { inherit pkgs; })
        {
          _module.args.name = "demo";
          env.DEMO_HOME = "$PWD/.demo";
          preamble = ''mkdir -p "$DEMO_HOME"'';

          # Stands in for a toolchain: reachable inside the environment, and
          # deliberately not installed system-wide by the NixOS module.
          packages = [ pkgs.hello ];

          entrypoints = {
            demo-hello = {
              doc = "Say hello";
              params = [
                "who"
                "*rest"
              ];
              # Opted in, so the recipe-rendering assertions below have something
              # to bite on. Entrypoints do not get a recipe by default.
              just.enable = true;
              text = ''echo "hello $1 in $DEMO_HOME"'';
            };
            demo-wrapper = {
              text = ''demo-hello "$@"'';
              runtimeEntrypoints = [ "demo-hello" ];
            };
            demo-bootstrap = {
              applyEnv = false;
              text = ''echo "no preamble here"'';
            };
          };
        }
      ];
    }).config;

  evalAssertions = [
    {
      name = "the dev shell sources the environment rather than re-rendering it";
      ok =
        lib.hasInfix "source /nix/store/" shell.devShell.shellHook
        && !lib.hasInfix "export DEMO_HOME" shell.devShell.shellHook;
    }
    {
      name = "the recipe name drops the shell's command prefix";
      ok = shell.justRecipes ? hello && !(shell.justRecipes ? demo-hello);
    }
    {
      name = "the doc carries through to the recipe";
      ok = shell.justRecipes.hello.doc == "Say hello";
    }
    {
      name = "recipes run in the invocation directory, not the justfile's";
      ok = lib.elem "no-cd" shell.justRecipes.hello.attributes;
    }
    {
      name = "recipe bodies exec the entrypoint without echoing the line";
      ok = lib.hasPrefix "@exec /nix/store/" shell.justRecipes.hello.body;
    }
    {
      name = "named parameters are quoted and variadic ones are not";
      ok =
        lib.hasInfix ''"{{who}}" {{rest}}'' shell.justRecipes.hello.body
        && !lib.hasInfix ''"{{rest}}"'' shell.justRecipes.hello.body;
    }
    {
      name = "the home module defines recipes under the shell's namespace";
      ok =
        shell.homeModule.programs.globalJust.namespaces.demo == shell.justRecipes
        && !(shell.homeModule.programs.globalJust ? recipes);
    }
    {
      name = "the NixOS module puts every entrypoint on PATH";
      # Three declared, plus the generated `demo-shell`.
      ok = lib.length shell.nixosModule.environment.systemPackages == 4;
    }
    {
      name = "a shell entrypoint is generated, and reachable as `jg demo::shell`";
      ok = shell.scripts ? demo-shell && shell.justRecipes ? shell;
    }
    {
      name = "an entrypoint gets no recipe unless it asks for one";
      # demo-wrapper and demo-bootstrap set no `just.enable`, so the only
      # recipes are the shell's own and the one that opted in.
      ok =
        lib.attrNames shell.justRecipes == [
          "hello"
          "shell"
        ];
    }
    {
      name = "the NixOS module installs entrypoints only, never the raw tools";
      ok =
        shell.nixosModule.environment.systemPackages == lib.attrValues shell.scripts
        && !lib.elem pkgs.hello shell.nixosModule.environment.systemPackages
        && lib.elem pkgs.hello shell.packages;
    }
  ];

  failed = lib.filter (a: !a.ok) evalAssertions;
in
if failed != [ ] then
  throw ''
    offline-devshells: the generic layer failed ${toString (lib.length failed)} evaluation assertion(s):
    ${lib.concatMapStringsSep "\n" (a: "  - ${a.name}") failed}
  ''
else
  pkgs.runCommandLocal "offline-devshells-generic-layer" { } ''
    fail() { echo "FAIL: $1" >&2; exit 1; }

    hello=${shell.scripts.demo-hello}/bin/demo-hello
    wrapper=${shell.scripts.demo-wrapper}/bin/demo-wrapper
    bootstrap=${shell.scripts.demo-bootstrap}/bin/demo-bootstrap

    # One environment, one file. The dev shell and every entrypoint source the
    # same path -- that identity is the property worth pinning, because two
    # renderings drift silently.
    env_file=${shell.envFile}
    grep -qF "source $env_file" "$hello" \
      || fail "the entrypoint does not source the environment"

    grep -qF 'export DEMO_HOME="$PWD/.demo"' "$env_file" \
      || fail "env missing from the rendered environment"

    grep -qF 'mkdir -p "$DEMO_HOME"' "$env_file" \
      || fail "preamble missing from the rendered environment"

    # The preamble sits outside the guard, so it re-runs and can recreate state
    # that was deleted between two commands; the exports sit inside it.
    guard_line=$(grep -n 'OFFLINE_DEVSHELL_demo' "$env_file" | head -1 | cut -d: -f1)
    export_line=$(grep -n 'export DEMO_HOME' "$env_file" | cut -d: -f1)
    fi_line=$(grep -n '^fi$' "$env_file" | head -1 | cut -d: -f1)
    preamble_line=$(grep -n 'mkdir -p' "$env_file" | cut -d: -f1)
    [ "$guard_line" -lt "$export_line" ] && [ "$export_line" -lt "$fi_line" ] \
      || fail "the exports are not inside the guard"
    [ "$preamble_line" -gt "$fi_line" ] \
      || fail "the preamble is inside the guard, so it would not re-run"

    grep -q "$env_file" "$bootstrap" \
      && fail "applyEnv = false did not suppress the environment"

    grep -qF '${shell.scripts.demo-hello}/bin' "$wrapper" \
      || fail "runtimeEntrypoints did not put the other entrypoint on PATH"

    # The bundle is the offline claim: everything the environment needs, in one
    # place, including the dev shell's own build inputs.
    for link in demo-hello demo-wrapper demo-bootstrap devshell-inputs; do
      [ -e "${shell.bundle}/$link" ] || fail "bundle is missing $link"
    done

    # And it really runs, outside any dev shell. (Not `out=`: that is the
    # derivation's own output path.)
    greeting=$("$hello" world)
    case "$greeting" in
      "hello world in "*/.demo) ;;
      *) fail "entrypoint produced: $greeting" ;;
    esac

    # The generated shell entrypoint hands the environment to an arbitrary
    # command -- every other entrypoint on PATH, and the env applied.
    shell=${shell.scripts.demo-shell}/bin/demo-shell
    "$shell" sh -c 'command -v demo-hello >/dev/null' \
      || fail "runtimeAll did not put the other entrypoints on PATH"
    "$shell" sh -c 'command -v hello >/dev/null' \
      || fail "runtimeAll did not put the shell's packages on PATH"
    [ "$("$shell" sh -c 'echo "$DEMO_HOME"')" = "$PWD/.demo" ] \
      || fail "the shell entrypoint did not apply the environment"

    # Entering fresh, the environment wins over whatever the caller had set --
    # an offline environment must not be pointed elsewhere by a stray variable.
    [ "$(DEMO_HOME=/somewhere/else "$shell" sh -c 'echo "$DEMO_HOME"')" = "$PWD/.demo" ] \
      || fail "a caller's value survived entry into the environment"

    # But a command run from *inside* it inherits what is already established,
    # rather than recomputing a $PWD-relative value against a subdirectory.
    mkdir -p sub
    nested=$("$shell" sh -c "cd sub && $hello nested")
    case "$nested" in
      "hello nested in $PWD/.demo") ;;
      *) fail "nested command recomputed the environment: $nested" ;;
    esac

    touch $out
  ''
