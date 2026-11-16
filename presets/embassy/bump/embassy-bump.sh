#!/usr/bin/env bash
# embassy-bump: move the embassy preset to current embassy main, re-resolve both
# crate sets, and prove the result builds -- or put everything back and say why.
#
#   nix run .#embassy-bump [-- options]
#
#   --rev REV            pin embassy to REV instead of current main
#   --summary FILE       also write a Markdown summary (the workflow's PR body)
#   --keep-on-failure    leave the bumped tree in place when a step fails, to fix
#                        by hand (the example firmware, say) and re-check
#   --no-verify          stop after re-resolving; skip `nix flake check` and the
#                        bundle build
#
# Steps, in order:
#   1. `nix flake update embassy`
#   2. evaluate the preset against the new tree: a crate crates.nix names that
#      the tree no longer has stops here
#   3. look up the newest crates.io release of every embassy crate crates-io
#      mode seeds, and write presets/embassy/versions.json
#   4. move Rust to the toolchain embassy's rust-toolchain.toml names (never
#      down), updating rust-overlay only if it does not have that version yet
#   5. `embassy-refresh-seed`: both locks and the git-mode vendor hash
#   6. rewrite the example firmwares' and the template's embassy versions
#   7. `nix flake check` and `nix build .#embassy`
#
# Every file it may touch is snapshotted first and restored on any failure, so a
# failed run leaves the tree exactly as it found it.
set -euo pipefail

system="@system@"
# Overridable for the test suite, which serves a fixture index from file://.
index_url="${EMBASSY_BUMP_INDEX_URL:-https://index.crates.io}"

usage() {
    cat <<'EOF'
usage: nix run .#embassy-bump [-- options]

  --rev REV            pin embassy to REV instead of current main
  --summary FILE       also write a Markdown summary (the workflow's PR body)
  --keep-on-failure    leave the bumped tree in place when a step fails
  --no-verify          skip `nix flake check` and the bundle build
EOF
}

rev=""
summary=""
restore_on_failure=1
verify=1
while [ "$#" -gt 0 ]; do
    case "$1" in
    --rev) rev="$2"; shift 2 ;;
    --summary) summary="$2"; shift 2 ;;
    --keep-on-failure) restore_on_failure=0; shift ;;
    --no-verify) verify=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "embassy-bump: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
done

root="$(pwd)"
if [ ! -f "$root/flake.nix" ] || [ ! -f "$root/presets/embassy/versions.json" ]; then
    echo "embassy-bump: run this from the root of offline-devshells." >&2
    exit 2
fi

pkg="$root#packages.$system.embassy-bump"
info() { nix eval --json "$pkg.info.$1"; }
step() { printf '\n==> %s\n' "$*" >&2; }

work="$(mktemp -d)"
snap="$work/snapshot"
mkdir -p "$snap"

# What went wrong and what a human should do about it, for the log, the job
# summary and the exit trap.
failure=""
fail() {
    failure="$1"
    exit 1
}

managed_json="$(info managedFiles)"
mapfile -t managed < <(jq -r '.[]' <<<"$managed_json")
for f in "${managed[@]}"; do
    if [ -e "$root/$f" ]; then
        mkdir -p "$snap/$(dirname "$f")"
        cp "$root/$f" "$snap/$f"
    fi
done

restore() {
    for f in "${managed[@]}"; do
        if [ -e "$snap/$f" ]; then
            cp "$snap/$f" "$root/$f"
        else
            rm -f "$root/$f"
        fi
    done
}

finished=0
on_exit() {
    local status=$?
    if [ "$finished" != 1 ] && [ "$status" != 0 ]; then
        {
            echo
            echo "embassy-bump: FAILED"
            if [ -n "$failure" ]; then
                printf '%s\n' "$failure" | sed 's/^/  /'
            fi
            echo
            if [ "$restore_on_failure" = 1 ]; then
                restore
                echo "Every file it touched has been put back; the tree is as it was."
                echo "To keep the bumped tree and fix it by hand, re-run with --keep-on-failure."
            else
                echo "--keep-on-failure: the bumped files are left in place:"
                printf '  %s\n' "${managed[@]}"
            fi
        } >&2
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
            printf '## embassy bump failed\n\n```\n%s\n```\n' "$failure" >>"$GITHUB_STEP_SUMMARY"
        fi
    fi
    rm -rf "$work"
}
trap on_exit EXIT

lockrev() { jq -r '.nodes.embassy.locked.rev' "$1"; }
old_rev="$(lockrev "$snap/flake.lock")"

# --- 1. the tree ---------------------------------------------------------------

step "moving embassy to ${rev:-current main}"
if [ -n "$rev" ]; then
    nix flake lock "$root" --override-input embassy "github:embassy-rs/embassy/$rev" ||
        fail "could not lock embassy at $rev"
else
    nix flake update embassy --flake "$root" || fail "nix flake update embassy failed (network?)"
fi
new_rev="$(lockrev "$root/flake.lock")"
echo "embassy: ${old_rev:0:12} -> ${new_rev:0:12}" >&2

# --- 2. does crates.nix still describe the tree? -------------------------------

step "checking crates.nix against the new tree"
if ! info gitCheck >"$work/git-dropped.json" 2>"$work/eval.err"; then
    cat "$work/eval.err" >&2
    fail "The new embassy tree no longer matches presets/embassy/crates.nix (see above).
A human has to decide what replaces what upstream removed or renamed."
fi

# What a tree crate offers, as cargo reads it (Nix cannot: TOML 1.1).
tree="$(info embassySrc | jq -r .)"
manifest() {
    (cd "$work" && CARGO_NET_OFFLINE=true cargo metadata --no-deps --format-version 1 \
        --manifest-path "$tree/$1/Cargo.toml") | jq -c '.packages[0]'
}

step "reading the new tree's manifests"
info gitRequests >"$work/git-requests.json"
echo '{}' >"$work/git.json"
while read -r name; do
    m="$(manifest "$name")" || fail "cargo could not read $name/Cargo.toml in the new embassy tree"
    jq --arg n "$name" --argjson m "$m" --slurpfile r "$work/git-requests.json" '
        ($r[0][$n] - ($m.features | keys)) as $u
        | if ($u | length) > 0 then .[$n] = { unavailable: $u } else . end' \
        "$work/git.json" >"$work/next" && mv "$work/next" "$work/git.json"
done < <(jq -r 'keys[]' "$work/git-requests.json")

# --- 3. crates.io --------------------------------------------------------------

# The sparse index path of a crate, per cargo's layout.
index_path() {
    local n="${1,,}"
    case "${#n}" in
    1) echo "1/$n" ;;
    2) echo "2/$n" ;;
    3) echo "3/${n:0:1}/$n" ;;
    *) echo "${n:0:2}/${n:2:2}/$n" ;;
    esac
}

# Newest non-yanked, non-prerelease release; which requested features it
# lacks; and the previous major, if this bump crosses one (or one was already
# being carried).
pick='
def semkey: split("+")[0] | split(".") | map(tonumber? // 0);
def compat: split(".") as $p | if $p[0] != "0" then $p[0] else $p[0:2] | join(".") end;
def avail($e):
  (($e.features // {}) + ($e.features2 // {})) as $f
  | ([$f[] | .[] | select(startswith("dep:")) | ltrimstr("dep:")]) as $claimed
  | ($f | keys) + ([$e.deps[] | select(.optional) | .name] - $claimed);
def entry($e): { version: $e.vers }
  + (($req - avail($e)) as $u | if ($u | length) > 0 then { unavailable: $u } else {} end);
[ .[] | select(.yanked | not) | select(.vers | test("-") | not) ] as $rel
| if ($rel | length) == 0 then error("no usable release on crates.io") else . end
| entry($rel | max_by(.vers | semkey)) as $new
| ( if $old == null then null
    elif ($old.version | compat) != ($new.version | compat) then $old.version
    else $old.previous.version // null end ) as $pv
| ( if $pv == null then null else ($rel | map(select(.vers == $pv)) | first) end ) as $pe
| $new + ( if $pe != null and ($pv | compat) != ($new.version | compat)
           then { previous: entry($pe) } else {} end )
'

step "looking up the newest crates.io releases"
info cratesIoRequests >"$work/requests.json"
echo '{}' >"$work/cratesio.json"
while read -r name; do
    if ! curl -fsS --retry 5 --retry-all-errors --retry-delay 3 \
        "$index_url/$(index_path "$name")" >"$work/index"; then
        fail "could not fetch the crates.io index entry for $name (network?)"
    fi
    req="$(jq -c --arg n "$name" '.[$n]' "$work/requests.json")"
    old="$(jq -c --arg n "$name" '.cratesIo[$n] // null' "$snap/presets/embassy/versions.json")"
    if ! entry="$(jq -s -c --argjson req "$req" --argjson old "$old" "$pick" "$work/index")"; then
        fail "$name: no usable release on crates.io. Was it removed or renamed? Update presets/embassy/crates.nix."
    fi
    jq --arg n "$name" --argjson e "$entry" '.[$n] = $e' "$work/cratesio.json" >"$work/next" &&
        mv "$work/next" "$work/cratesio.json"
done < <(jq -r 'keys[]' "$work/requests.json")

# --- 4. Rust -------------------------------------------------------------------

step "choosing the Rust toolchain"
old_rust="$(jq -r .rust "$snap/presets/embassy/versions.json")"
new_rust="$old_rust"
channel="$(info embassyChannel | jq -r '. // empty')"
newest_matching() {
    info rustAvailable | jq -r --arg c "$1" \
        '.[] | select(. == $c or startswith($c + "."))' | sort -V | tail -n1
}
if [[ "$channel" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    want="$(newest_matching "$channel")"
    if [ -z "$want" ]; then
        echo "rust-overlay has no Rust $channel yet; updating it" >&2
        nix flake update rust-overlay --flake "$root" || fail "nix flake update rust-overlay failed"
        want="$(newest_matching "$channel")"
    fi
    if [ -z "$want" ]; then
        fail "embassy's rust-toolchain.toml asks for Rust $channel, which even the newest
rust-overlay does not provide yet. Try again in a few days."
    fi
    new_rust="$(printf '%s\n%s\n' "$old_rust" "$want" | sort -V | tail -n1)"
else
    echo "embassy's rust-toolchain.toml names no version ('$channel'); keeping Rust $old_rust" >&2
fi
echo "rust: $old_rust -> $new_rust" >&2

jq -n --arg rust "$new_rust" --slurpfile c "$work/cratesio.json" --slurpfile g "$work/git.json" '{
  _comment: "GENERATED by `nix run .#embassy-bump`; see presets/embassy/versions.nix. rust: the toolchain the preset pins. cratesIo: the newest release of each embassy crate crates-io mode seeds, the requested features it lacks, and the previous major still seeded beside it. git: requested features the pinned tree lacks (versions come from the tree itself).",
  rust: $rust,
  cratesIo: $c[0],
  git: $g[0]
}' >"$root/presets/embassy/versions.json"

# --- 5. both crate sets --------------------------------------------------------

step "re-resolving both crate sets (embassy-refresh-seed)"
nix run "$root#embassy-refresh-seed" -- "$root" ||
    fail "embassy-refresh-seed failed (output above). If cargo could not resolve, the
message names the crate and feature; a feature or crate crates.nix asks for may
have gone upstream."

# Publishable tree crates that neither crates.nix nor anything it pulls in
# uses, for the summary: candidates for widening the set.
unseeded=()
while read -r name; do
    if ! grep -qx "name = \"$name\"" "$root/presets/embassy/locks/git.lock" &&
        m="$(manifest "$name" 2>/dev/null)" &&
        jq -e '.publish != []' <<<"$m" >/dev/null; then
        unseeded+=("$name")
    fi
done < <(info treeCrates | jq -r '.[]')

# --- 6. the manifests that name versions ---------------------------------------

step "rewriting the example firmwares' and the template's versions"
synced="$(nix build --no-link --print-out-paths "$pkg.synced")" ||
    fail "could not compute the rewritten manifests"
(cd "$synced" && find . -type f) | while read -r f; do
    install -m 0644 "$synced/$f" "$root/$f"
done

# --- what changed ---------------------------------------------------------------

changed=()
for f in "${managed[@]}"; do
    if ! cmp -s "$snap/$f" "$root/$f"; then
        changed+=("$f")
    fi
done

report="$(info report)"

write_summary() {
    {
        if [ "$old_rev" = "$new_rev" ]; then
            echo "embassy stays at \`${new_rev:0:12}\`."
        else
            echo "embassy: \`${old_rev:0:12}\` → \`${new_rev:0:12}\` ([compare](https://github.com/embassy-rs/embassy/compare/$old_rev...$new_rev))"
        fi
        echo
        if [ "$old_rust" != "$new_rust" ]; then
            echo "Rust: $old_rust → $new_rust (embassy's rust-toolchain.toml)"
            echo
        fi
        moved="$(jq -r --slurpfile old "$snap/presets/embassy/versions.json" '
            .cratesIo | to_entries[]
            | ($old[0].cratesIo[.key].version // "new") as $o
            | select($o != .value.version)
            | "| `\(.key)` | \($o) | \(.value.version) |"' "$root/presets/embassy/versions.json")"
        if [ -n "$moved" ]; then
            echo "Newest crates.io releases (crates-io mode):"
            echo
            echo "| crate | was | now |"
            echo "|---|---|---|"
            echo "$moved"
            echo
        fi
        echo "Both crate sets re-resolved with \`embassy-refresh-seed\`: the crates.io"
        echo "lock moves to current releases of *everything* in it, not only embassy."
        echo
        dropped="$(jq -r '.dropped[] | "| \(.mode) | `\(.crate)` \(.version) | `\(.feature)` |"' <<<"$report")"
        if [ -n "$dropped" ]; then
            echo "Features crates.nix asks for that the chosen version does not have (dropped;"
            echo "check none of them was a rename that gated a dependency):"
            echo
            echo "| mode | crate | feature |"
            echo "|---|---|---|"
            echo "$dropped"
            echo
        fi
        if [ "${#unseeded[@]}" -gt 0 ]; then
            echo "Publishable crates in the tree that crates.nix does not seed (git mode"
            echo "patches them in, but their own dependencies are not vendored):"
            printf '`%s` ' "${unseeded[@]}"
            echo
            echo
        fi
        if [ "${#changed[@]}" -gt 0 ]; then
            echo "Files changed:"
            printf -- '- `%s`\n' "${changed[@]}"
        else
            echo "Nothing changed."
        fi
    } >"$work/summary.md"
    cat "$work/summary.md" >&2
    if [ -n "$summary" ]; then cp "$work/summary.md" "$summary"; fi
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat "$work/summary.md" >>"$GITHUB_STEP_SUMMARY"; fi
}

if [ "${#changed[@]}" -eq 0 ]; then
    step "nothing to do"
    write_summary
    finished=1
    exit 0
fi

# --- 7. prove it ---------------------------------------------------------------

# Run a build, streaming its output and keeping a copy to diagnose from.
logged() {
    local status
    set +e
    "$@" 2>&1 | tee "$work/build.log"
    status=${PIPESTATUS[0]}
    set -e
    return "$status"
}

diagnose() {
    local log="$work/build.log" which="the build"
    if grep -q 'blinky-mspm0' "$log" && grep -q 'error' "$log"; then
        which="the MSPM0 example firmware (git mode, presets/embassy/firmware-mspm0)"
    elif grep -q 'blinky' "$log" && grep -q 'error' "$log"; then
        which="the STM32 example firmware (crates-io mode, presets/embassy/firmware)"
    fi
    if grep -Eq 'error\[E[0-9]+\]' "$log"; then
        echo "$which no longer compiles against the new embassy: an upstream API change.
Fix its src/ (the rustc errors are above), then re-run the bump."
    elif grep -Eq 'failed to select a version|does not have (that|the) feature|no matching package' "$log"; then
        echo "$which cannot resolve: its Cargo.toml asks for a feature or crate the new
version does not have (cargo's message is above). Update that Cargo.toml."
    elif grep -Eq 'requires rustc|is not supported by|unstable|edition20[0-9]+' "$log"; then
        echo "$which needs a newer Rust than $new_rust. Raise \"rust\" in
presets/embassy/versions.json (rust-overlay must provide it) and re-run."
    else
        echo "$which failed (output above)."
    fi
}

if [ "$verify" = 1 ]; then
    step "nix flake check"
    logged nix flake check "$root" --print-build-logs || fail "$(diagnose)"
    step "nix build .#embassy (the offline bundle)"
    logged nix build --no-link --print-build-logs "$root#embassy" || fail "$(diagnose)"
fi

step "done"
write_summary
finished=1
