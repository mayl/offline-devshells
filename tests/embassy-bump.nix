# `embassy-bump`'s control flow, without Nix, the network or embassy.
#
# A stub `nix` answers the script's evaluations from fixture files and plays
# each step (flake update, refresh-seed, flake check) as the scenario says; the
# crates.io index is a fixture served over file://; `cargo metadata` is real,
# reading a two-crate fixture tree. What is checked is what makes the bump safe
# to run unattended:
#
#   * a crate gone from the tree stops it before anything is resolved, and the
#     lock is put back;
#   * a firmware that no longer compiles stops it with the right diagnosis, and
#     every file is put back -- or, with --keep-on-failure, left for a human;
#   * a successful run writes versions.json (newest release, previous major kept
#     when one is crossed, missing features recorded) and the summary;
#   * a run with nothing new changes nothing and builds nothing.
{
  pkgs,
  lib,
  bump,
}:
let
  tree = ./fixtures/embassy-tree;

  # One line per release, as the sparse index serves them.
  index = pkgs.writeText "embassy-foo-index" (
    lib.concatMapStrings (r: builtins.toJSON r + "\n") [
      {
        name = "embassy-foo";
        vers = "0.3.5";
        yanked = false;
        features.defmt = [ ];
        deps = [ ];
      }
      {
        name = "embassy-foo";
        vers = "0.4.0";
        yanked = false;
        features.defmt = [ ];
        deps = [
          {
            name = "log";
            optional = true;
          }
        ];
      }
      {
        name = "embassy-foo";
        vers = "0.5.0-alpha.1";
        yanked = false;
        features = { };
        deps = [ ];
      }
      {
        name = "embassy-foo";
        vers = "0.4.1";
        yanked = true;
        features = { };
        deps = [ ];
      }
    ]
  );

  # Plays `nix` for the script. $SCENARIO picks how each step goes; $CALLS
  # records what was asked.
  stubNix = pkgs.writeShellScript "nix" ''
    echo "$*" >>"$CALLS"
    case "$1 $2" in
    "eval --json")
      attr="''${3##*.info.}"
      case "$attr" in
      managedFiles) echo '["flake.lock","presets/embassy/versions.json","locks/a.lock","fw/Cargo.toml"]' ;;
      gitCheck)
        if [ "$SCENARIO" = removed ]; then
          echo "error: \`embassy-gone' is no longer in the pinned embassy tree" >&2
          exit 1
        fi
        echo '[]' ;;
      embassySrc) echo '"${tree}"' ;;
      gitRequests) echo '{"embassy-foo":["defmt","gone"]}' ;;
      cratesIoRequests) echo '{"embassy-foo":["defmt","log","gone"]}' ;;
      embassyChannel) echo '"stable"' ;;
      rustAvailable) echo '[]' ;;
      treeCrates) echo '["embassy-bar","embassy-foo"]' ;;
      report) echo '{"dropped":[{"mode":"git","crate":"embassy-foo","version":"0.3.1","feature":"gone"}]}' ;;
      *) echo "stub nix: unexpected eval $attr" >&2; exit 1 ;;
      esac ;;
    "flake update")
      if [ "$SCENARIO" != unchanged ]; then
        echo '{"nodes":{"embassy":{"locked":{"rev":"bbbbbbbbbbbbbbbb"}}}}' >flake.lock
      fi ;;
    "run "*)
      if [ "$SCENARIO" != unchanged ]; then
        echo 'resolved = "new"' >locks/a.lock
      fi ;;
    "build --no-link")
      if [ "$3" = --print-out-paths ]; then
        mkdir -p "$TMPDIR/synced/fw"
        cp fw/Cargo.toml "$TMPDIR/synced/fw/Cargo.toml"
        echo "$TMPDIR/synced"
      fi ;;
    "flake check")
      if [ "$SCENARIO" = broken ]; then
        echo "building '/nix/store/xxx-blinky-mspm0-0.1.0.drv'..."
        echo "error[E0425]: cannot find function \`init\` in crate \`embassy_mspm0\`"
        exit 1
      fi ;;
    *) echo "stub nix: unexpected: $*" >&2; exit 1 ;;
    esac
  '';
in
pkgs.runCommandLocal "offline-devshells-embassy-bump"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.diffutils
    ];
  }
  ''
    fail() { echo "FAIL: $1" >&2; exit 1; }
    export CARGO_HOME=$TMPDIR/cargo-home CARGO_NET_OFFLINE=true
    mkdir -p stubs index/em/ba
    cp ${stubNix} stubs/nix
    cp ${index} index/em/ba/embassy-foo
    export PATH=$PWD/stubs:$PATH
    export EMBASSY_BUMP_INDEX_URL=file://$PWD/index
    export CALLS=$PWD/calls

    mkrepo() {
      rm -rf repo && mkdir -p repo/presets/embassy repo/locks repo/fw
      touch repo/flake.nix
      echo '{"nodes":{"embassy":{"locked":{"rev":"aaaaaaaaaaaaaaaa"}}}}' >repo/flake.lock
      echo '{"rust":"1.0.0","cratesIo":{"embassy-foo":{"version":"0.3.5"}},"git":{}}' \
        >repo/presets/embassy/versions.json
      echo 'resolved = "old"' >repo/locks/a.lock
      echo '[dependencies]' >repo/fw/Cargo.toml
      cp -r repo pristine
      : >"$CALLS"
    }
    unchanged() { diff -r pristine repo >/dev/null; }
    run() { (cd repo && SCENARIO=$1 ${lib.getExe bump} "''${@:2}") >log 2>&1; }

    # --- a crate gone from the tree ---
    mkrepo
    if run removed; then cat log; fail "a removed crate did not stop the bump"; fi
    unchanged || { diff -r pristine repo; fail "flake.lock was not put back"; }
    grep -q 'no longer matches presets/embassy/crates.nix' log || { cat log; fail "no diagnosis for a removed crate"; }
    grep -q 'run ' "$CALLS" && fail "refresh-seed ran after the tree check failed"
    rm -rf pristine

    # --- a firmware that no longer compiles ---
    mkrepo
    if run broken; then cat log; fail "a failing build did not fail the bump"; fi
    unchanged || { diff -r pristine repo; fail "the files were not put back after a failed build"; }
    grep -q 'MSPM0 example firmware' log || { cat log; fail "the failing firmware was not named"; }
    grep -q 'upstream API change' log || { cat log; fail "a compile error was not diagnosed as an API change"; }
    rm -rf pristine

    mkrepo
    if run broken --keep-on-failure; then fail "a failing build did not fail the bump"; fi
    grep -q '"new"' repo/locks/a.lock || { cat log; fail "--keep-on-failure did not keep the bumped files"; }
    rm -rf pristine

    # --- success ---
    mkrepo
    run ok --summary "$PWD/summary.md" || { cat log; fail "a clean bump failed"; }
    v=repo/presets/embassy/versions.json
    [ "$(jq -r '.cratesIo."embassy-foo".version' $v)" = 0.4.0 ] \
      || { cat $v; fail "not the newest non-yanked, non-prerelease release"; }
    [ "$(jq -r '.cratesIo."embassy-foo".previous.version' $v)" = 0.3.5 ] \
      || { cat $v; fail "the previous major was not kept"; }
    [ "$(jq -c '.cratesIo."embassy-foo".unavailable' $v)" = '["gone"]' ] \
      || { cat $v; fail "crates.io's missing features were not recorded"; }
    [ "$(jq -c '.git."embassy-foo".unavailable' $v)" = '["gone"]' ] \
      || { cat $v; fail "the tree's missing features were not recorded"; }
    [ "$(jq -r .rust $v)" = 1.0.0 ] || fail "Rust moved although embassy names no version"
    grep -q 'aaaaaaaaaaaa.*bbbbbbbbbbbb' summary.md || { cat summary.md; fail "the summary lacks the revisions"; }
    grep -q '`embassy-foo` | 0.3.5 | 0.4.0' summary.md || { cat summary.md; fail "the summary lacks the version move"; }
    grep -q '`gone`' summary.md || { cat summary.md; fail "the summary lacks the dropped feature"; }
    grep -q '`embassy-bar`' summary.md || { cat summary.md; fail "the summary lacks the unseeded crate"; }
    grep -q 'flake check' "$CALLS" || fail "the result was not checked"
    rm -rf pristine

    # --- nothing new ---
    mkrepo
    # Already at the newest release, with everything recorded.
    jq -n '{rust: "1.0.0", cratesIo: {"embassy-foo": {version: "0.4.0", unavailable: ["gone"], previous: {version: "0.3.5"}}}, git: {"embassy-foo": {unavailable: ["gone"]}}}' \
      >repo/presets/embassy/versions.json
    # Byte-for-byte what the script writes, so only a real change shows.
    run unchanged || { cat log; fail "the nothing-to-do run failed"; }
    cp repo/presets/embassy/versions.json pristine/presets/embassy/versions.json
    : >"$CALLS"
    run unchanged || { cat log; fail "the nothing-to-do run failed"; }
    unchanged || { diff -r pristine repo; fail "a run with nothing new changed files"; }
    grep -q 'nothing to do' log || { cat log; fail "no 'nothing to do'"; }
    grep -q 'flake check' "$CALLS" && fail "a run with nothing new still built"

    touch $out
  ''
