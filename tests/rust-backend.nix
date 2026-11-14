# The rust backend, without a real toolchain or a single crate download.
#
# `rust.toolchain` is assigned a stub, which bypasses rust-overlay entirely, and
# the locks are small fixtures. What is checked:
#
#   * at evaluation time: the errors a user hits first -- a placeholder lock, a
#     `defaultMode` that names no mode, a `lockPath` that is not `lockFile` --
#     fail evaluation rather than surfacing deep inside nixpkgs;
#   * at build time: the rendered seed workspace, and refresh-seed's hash
#     learning, driven by stub `cargo` and `nix` commands. The latter is the part
#     that once left a placeholder hash behind on every run.
{ pkgs, lib }:
let
  # `cargo generate-lockfile --manifest-path <dir>/Cargo.toml` writes a lock
  # beside the manifest. That is all refresh-seed asks of cargo.
  stubToolchain = pkgs.writeShellScriptBin "cargo" ''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --manifest-path) manifest="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'version = 4\n# resolved by the stub\n' >"$(dirname "$manifest")/Cargo.lock"
  '';

  evalShell =
    rust:
    (lib.evalModules {
      modules = [
        (import ../modules/shell-submodule.nix { inherit pkgs; })
        {
          _module.args.name = "demo";
          rust = {
            version = "0.0.0";
            toolchain = stubToolchain;
          }
          // rust;
        }
      ];
    }).config;

  shell = evalShell {
    defaultMode = "registry";
    modes.registry = {
      crates.common = {
        heapless = "0.9";
        serde = {
          version = "1";
          features = [ "derive" ];
          defaultFeatures = false;
        };
        heapless-08 = {
          package = "heapless";
          version = "0.8";
        };
      };
      lockFile = ./fixtures/one-crate.lock;
      lockPath = "tests/fixtures/one-crate.lock";
    };
    modes.hashed = {
      crates.common.cfg-if = "1";
      lockFile = ./fixtures/one-crate.lock;
      lockPath = "tests/fixtures/one-crate.lock";
      vendorHashFile = ./fixtures/vendor-hash.nix;
      vendorHashPath = "tests/fixtures/vendor-hash.nix";
    };
  };

  fails = x: !(builtins.tryEval (builtins.deepSeq x x)).success;

  evalAssertions = [
    {
      name = "a resolved lock evaluates to a vendor directory";
      ok = !fails shell.rust.modes.registry.vendorDir.drvPath;
    }
    {
      name = "a placeholder lock is refused at evaluation";
      ok =
        fails
          (evalShell {
            modes.m = {
              crates.common.cfg-if = "1";
              lockFile = ./fixtures/placeholder.lock;
              lockPath = "tests/fixtures/placeholder.lock";
            };
          }).rust.modes.m.vendorDir.drvPath;
    }
    {
      name = "refresh-seed still evaluates against a placeholder lock";
      ok =
        !fails
          (evalShell {
            modes.m = {
              crates.common.cfg-if = "1";
              lockFile = ./fixtures/placeholder.lock;
              lockPath = "tests/fixtures/placeholder.lock";
            };
          }).scripts.demo-refresh-seed.drvPath;
    }
    {
      name = "a defaultMode that names no mode is refused";
      ok =
        fails
          (evalShell {
            defaultMode = "nope";
            modes.m = {
              lockFile = ./fixtures/one-crate.lock;
              lockPath = "tests/fixtures/one-crate.lock";
            };
          }).envFile.drvPath;
    }
    {
      name = "a lockPath that does not name lockFile is refused";
      ok =
        fails
          (evalShell {
            modes.m = {
              lockFile = ./fixtures/one-crate.lock;
              lockPath = "tests/fixtures/elsewhere.lock";
            };
          }).scripts.demo-refresh-seed.drvPath;
    }
    {
      name = "the mode command's tables name every mode";
      ok =
        let
          text = shell.entrypoints.demo-mode.substitutions.modeTables.text;
        in
        lib.hasInfix "configs=(" text && lib.hasInfix "registry]=" text && lib.hasInfix "hashed]=" text;
    }
  ];

  failed = lib.filter (a: !a.ok) evalAssertions;

  seed = shell.rust.modes.registry.seed;
  refresh = "${shell.scripts.demo-refresh-seed}/bin/demo-refresh-seed";
in
if failed != [ ] then
  throw ''
    offline-devshells: the rust backend failed ${toString (lib.length failed)} evaluation assertion(s):
    ${lib.concatMapStringsSep "\n" (a: "  - ${a.name}") failed}
  ''
else
  pkgs.runCommandLocal "offline-devshells-rust-backend" { } ''
    fail() { echo "FAIL: $1" >&2; exit 1; }

    # --- the seed workspace ---
    manifest=${seed}/crates/common/Cargo.toml
    grep -qx 'heapless = "0.9"' "$manifest" \
      || fail "a bare version did not render in the shorthand form"
    grep -qx 'serde = { version = "1", features = \["derive"\], default-features = false }' "$manifest" \
      || fail "a full dependency spec rendered wrongly"
    grep -qx 'heapless-08 = { version = "0.8", package = "heapless" }' "$manifest" \
      || fail "a renamed dependency rendered wrongly"
    grep -q '"crates/common"' ${seed}/Cargo.toml \
      || fail "the member is missing from the workspace"

    # --- refresh-seed, against a scratch copy of the repository layout ---
    stubs=$PWD/stubs
    mkdir -p "$stubs"
    mkrepo() {
      rm -rf repo && mkdir -p repo/tests/fixtures
      cp ${./fixtures/one-crate.lock} repo/tests/fixtures/one-crate.lock
      cp ${./fixtures/vendor-hash.nix} repo/tests/fixtures/vendor-hash.nix
      chmod -R u+w repo
    }
    stub_nix() {
      printf '#!${pkgs.runtimeShell}\n%s\n' "$1" >"$stubs/nix"
      chmod +x "$stubs/nix"
    }

    # A hash mismatch, as Nix reports it: the build fails, and says what it got.
    mkrepo
    stub_nix 'echo "error: hash mismatch in fixed-output derivation"; echo "         specified: sha256-AAAA"; echo "            got:    sha256-LEARNED="; exit 1'
    PATH="$stubs:$PATH" ${refresh} repo >log 2>&1 || { cat log; fail "refresh-seed failed on a hash mismatch"; }
    grep -qx '"sha256-LEARNED="' repo/tests/fixtures/vendor-hash.nix \
      || { cat log repo/tests/fixtures/vendor-hash.nix; fail "the learned hash was not written"; }
    grep -q '^# Header comment' repo/tests/fixtures/vendor-hash.nix \
      || fail "the hash file's header was not preserved"
    grep -q 'resolved by the stub' repo/tests/fixtures/one-crate.lock \
      || fail "the lock was not rewritten"

    # Any other failure: the old hash comes back, and the build output is shown.
    mkrepo
    stub_nix 'echo "error: something unrelated broke"; exit 1'
    if PATH="$stubs:$PATH" ${refresh} repo >log 2>&1; then
      fail "refresh-seed succeeded although the hash could not be learned"
    fi
    cmp -s repo/tests/fixtures/vendor-hash.nix ${./fixtures/vendor-hash.nix} \
      || { cat repo/tests/fixtures/vendor-hash.nix; fail "the previous hash was not restored"; }
    grep -q 'something unrelated broke' log \
      || { cat log; fail "the build output was swallowed"; }

    # A lock directory that is not there: say whose locks these are.
    mkdir -p empty
    if PATH="$stubs:$PATH" ${refresh} empty >log 2>&1; then
      fail "refresh-seed succeeded with nowhere to write"
    fi
    grep -q 'another' log || { cat log; fail "no hint that the locks may belong to another flake"; }

    touch $out
  ''
