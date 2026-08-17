#!/usr/bin/env bash
# Re-resolve every offline crate set against the real crates.io, and write the
# results back into the repository. Needs network, so it deliberately ignores the
# offline cargo config the environment installs.
#
# One lock per mode. Modes with a `[patch.crates-io]` table are resolved with it
# active, so what lands in their lock is the set of *registry* crates the patched
# tree needs -- which drifts ahead of what the published releases need.
#
# Modes with a vendor hash file get that refreshed too: `fetchCargoVendor` is a
# fixed-output derivation, so its hash has to move whenever the lock does.
#
# Patched modes are slow (10-15 minutes is normal). Almost all of that is
# fetching the crates.io sparse index, not resolving.
#
# GENERATED from offline-devshells' rust backend: the mode tables below are
# substituted from `rust.modes`.
set -euo pipefail

prefix="@commandPrefix@"
shell_name="@shellName@"

# Any syntactically valid SRI hash that cannot be the real one; Nix reports the
# correct hash when this fails to match.
placeholder="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

read -r -a modes <<<"@modeList@"

declare -A seeds=(
@modeSeeds@)

declare -A lock_paths=(
@modeLockPaths@)

declare -A online_configs=(
@modeOnlineConfigs@)

declare -A hash_paths=(
@modeHashPaths@)

root="${1:-.}"
root="$(cd "$root" && pwd)"

# The offline config the preamble installed would defeat the entire point.
export CARGO_NET_OFFLINE=false
unset CARGO_HOME

updated=()

for mode in "${modes[@]}"; do
    lock_path="${lock_paths[$mode]}"
    echo "==> $mode -> $lock_path"

    if [ ! -d "$(dirname "$root/$lock_path")" ]; then
        echo "$prefix-refresh-seed: no directory for '$lock_path' under $root" >&2
        exit 1
    fi

    # The seed workspace lives in the store and is read-only, so resolve in a
    # copy. The existing lock is seeded in first, so resolution keeps the pins it
    # can and this stays an update rather than a from-scratch re-resolve.
    work="$(mktemp -d)"
    cp -r --no-preserve=mode "${seeds[$mode]}"/. "$work/"
    if [ -f "$root/$lock_path" ]; then
        install -m 0644 "$root/$lock_path" "$work/Cargo.lock"
    fi

    home="$(mktemp -d)"
    install -m 0644 "${online_configs[$mode]}" "$home/config.toml"

    CARGO_HOME="$home" cargo generate-lockfile --manifest-path "$work/Cargo.toml"

    install -m 0644 "$work/Cargo.lock" "$root/$lock_path"
    updated+=("$lock_path")
done

for mode in "${modes[@]}"; do
    hash_path="${hash_paths[$mode]}"
    [ -n "$hash_path" ] || continue

    echo "==> $mode vendor hash -> $hash_path"
    hash_file="$root/$hash_path"

    # Everything but the quoted SRI string on its own line is the file's header
    # comment, and is preserved verbatim.
    header="$(sed '/^"/d' "$hash_file")"
    previous="$(sed -n 's/^"\(.*\)"$/\1/p' "$hash_file")"

    # Learn the real hash the only way Nix offers: write a hash that cannot be
    # right, build, and read back the one it reports.
    printf '%s\n"%s"\n' "$header" "$placeholder" >"$hash_file"
    got="$(
        nix build --no-link "$root#$shell_name-vendor-$mode" 2>&1 |
            sed -n 's/^ *got: *//p' | head -n1
    )"

    if [ -z "$got" ]; then
        # No mismatch reported means either the placeholder was already correct,
        # which cannot happen, or the build failed for an unrelated reason.
        # Either way, do not leave the placeholder behind.
        printf '%s\n"%s"\n' "$header" "$previous" >"$hash_file"
        echo "$prefix-refresh-seed: could not determine the vendor hash for '$mode';" >&2
        echo "  see the build output above. $hash_path is unchanged." >&2
        exit 1
    fi

    printf '%s\n"%s"\n' "$header" "$got" >"$hash_file"
    updated+=("$hash_path")
done

{
    echo
    echo "updated, under $root:"
    printf '  %s\n' "${updated[@]}"
    echo
    echo "now run: nix build"
} >&2
