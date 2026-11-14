#!/usr/bin/env bash
# Switch the environment between the vendored crate sets, and answer which one
# is active.
#
# Each mode is a single, self-consistent resolution with its own vendor
# directory; cargo allows only one replacement for crates.io, so they cannot be
# merged. Switching rewrites $CARGO_HOME/config.toml.
#
# The active mode is recorded in a marker file rather than inferred from the
# config's contents: "the config has a [patch.crates-io] table" is not the same
# question as "the mode is git", and would answer wrongly the moment a
# registry-only mode needs a patch for some unrelated crate. Other entrypoints
# read that file via `<prefix>-mode current`.
#
# Locks are resolution-specific: after switching, delete Cargo.lock and
# regenerate it in any project that was resolved in another mode.
#
# GENERATED from offline-devshells' rust backend: the mode tables are a
# generated file, sourced below.
set -euo pipefail

prefix="@commandPrefix@"
marker="$CARGO_HOME/$prefix-mode"

# Filled in by the sourced file, from `rust.modes`.
declare -A configs=() descriptions=()
# shellcheck source=/dev/null  # a store path, generated from `rust.modes`
source "@modeTables@"

usage() {
    {
        echo "usage: $prefix-mode [<mode>|status|current]"
        echo
        for m in "${!configs[@]}"; do
            printf '  %-12s %s\n' "$m" "${descriptions[$m]}"
        done
        echo "  status       human-readable summary"
        echo "  current      just the mode name, for scripts"
    } >&2
}

case "${1:-status}" in
    current)
        cat "$marker" 2>/dev/null || echo unset
        ;;
    status)
        echo "$prefix-mode: $(cat "$marker" 2>/dev/null || echo unset)"
        ;;
    -h | --help)
        usage
        ;;
    *)
        mode="$1"
        if [ -z "${configs[$mode]+set}" ]; then
            echo "$prefix-mode: no such mode: $mode" >&2
            usage
            exit 2
        fi
        install -m 0644 "${configs[$mode]}" "$CARGO_HOME/config.toml"
        printf '%s\n' "$mode" >"$marker"
        echo "$prefix-mode: $mode (${descriptions[$mode]})"
        echo "  delete Cargo.lock and regenerate it in projects that were"
        echo "  resolved in another mode."
        ;;
esac
