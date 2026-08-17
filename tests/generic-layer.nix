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

          entrypoints = {
            demo-hello = {
              doc = "Say hello";
              params = [
                "who"
                "*rest"
              ];
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
      name = "env reaches the dev shell hook, exported outright";
      ok = lib.hasInfix ''export DEMO_HOME="$PWD/.demo"'' shell.devShell.shellHook;
    }
    {
      name = "preamble reaches the dev shell hook";
      ok = lib.hasInfix ''mkdir -p "$DEMO_HOME"'' shell.devShell.shellHook;
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
      name = "recipe bodies run in the invocation directory, not the justfile's";
      ok = lib.hasPrefix ''@cd "{{invocation_directory()}}" && exec '' shell.justRecipes.hello.body;
    }
    {
      name = "named parameters are quoted and variadic ones are not";
      ok =
        lib.hasInfix ''"{{who}}" {{rest}}'' shell.justRecipes.hello.body
        && !lib.hasInfix ''"{{rest}}"'' shell.justRecipes.hello.body;
    }
    {
      name = "the home module defines recipes under the shell's namespace";
      ok = shell.homeModule.programs.globalJust.recipes ? demo;
    }
    {
      name = "the NixOS module puts every entrypoint on PATH";
      ok = lib.length shell.nixosModule.environment.systemPackages == 3;
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

    # `:=` and not `=`: an entrypoint must not clobber an environment the dev
    # shell already set, which is what lets one script serve both routes.
    grep -qF ': "''${DEMO_HOME:=$PWD/.demo}"' "$hello" \
      || fail "env missing from the entrypoint preamble, or not applied as a default"

    grep -qF 'mkdir -p "$DEMO_HOME"' "$hello" \
      || fail "preamble missing from the entrypoint"

    grep -q 'DEMO_HOME' "$bootstrap" \
      && fail "applyEnv = false did not suppress the preamble"

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

    touch $out
  ''
