#!/usr/bin/env bash
# Scaffold a project by copying one of embassy's own examples out of the pinned
# git tree.
#
# There is no single generator covering every embassy target -- upstream's own
# docs point at cargo-embassy (STM32/nRF), two different cargo-generate
# templates (STM32/nRF/RP), and esp-generate (ESP32), then tell you to copy from
# examples/ for anything else. Since examples/ covers *every* supported family,
# including the ones that exist only in git (mspm0, imxrt, mcxa, nxp,
# microchip), copying from there is the one mechanism that works everywhere.
#
# The rewrite this does is close to what the embassy book describes by hand:
# repoint the `path = "../../embassy-*"` keys at the pinned checkout, drop the
# workspace-only metadata, and give the package its own name.
set -euo pipefail

embassy_src="@embassySrc@"
examples="$embassy_src/examples"

list_examples() {
    find "$examples" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | pr -t -3 -w 78
}

if [ "$#" -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    cat >&2 <<USAGE
usage: embassy-from-example <example> [project-name]

Copies embassy's own example for a chip family and rewrites it into a
standalone project. Requires git mode (embassy-mode git).

  embassy-from-example mspm0g3507
  embassy-from-example stm32g4 my-project

Available examples:
USAGE
    list_examples >&2
    exit 2
fi

example="$1"
name="${2:-$example}"
src="$examples/$example"

if [ ! -d "$src" ]; then
    echo "embassy-from-example: no example named '$example'" >&2
    echo "available:" >&2
    list_examples >&2
    exit 1
fi

if [ -e "$name" ]; then
    echo "embassy-from-example: '$name' already exists" >&2
    exit 1
fi

if [ "$(embassy-mode current)" != "git" ]; then
    cat >&2 <<'EOF'
embassy-from-example: this needs git mode, because the examples depend on the
tree by path and several families (mspm0, imxrt, mcxa, nxp, microchip) are not
published to crates.io at all. Run:

    embassy-mode git
EOF
    exit 1
fi

if [ ! -f "$src/Cargo.toml" ]; then
    echo "embassy-from-example: '$example' has no top-level Cargo.toml" >&2
    echo "(some examples, like 'boot', are directories of sub-projects)" >&2
    exit 1
fi

# A handful of examples pull crates straight from git (assign-resources,
# reqwless, defmt-serial, embedded-fatfs, stm32wb-hci, nrf-pac). Those git
# revisions are not in the vendor directory -- the crates.io `stm32wb-hci`
# release the seed vendors is a different source as far as cargo is concerned
# -- and cargo's own error for it is unhelpful, so say plainly what is wrong
# before creating anything.
#
# `|| true`: grep exits 1 when nothing matches, and pipefail would turn that
# into an aborted script under `set -e`.
unvendorable="$(
    { grep -oE '^[A-Za-z0-9_-]+[[:space:]]*=[[:space:]]*\{[^}]*\bgit[[:space:]]*=' "$src/Cargo.toml" || true; } |
        sed -E 's/[[:space:]]*=.*//' | sort -u | sed 's/^/    /'
)"
if [ -n "$unvendorable" ]; then
    cat >&2 <<EOF
embassy-from-example: example '$example' depends on crates that embassy itself
takes from git rather than crates.io:

${unvendorable}

Those are not vendored here, so this example cannot be built offline. Pin the
repositories as flake inputs and patch them in (the way embassy-mspm0's
mspm0-metapac is handled), or pick a different example.
EOF
    exit 1
fi

cp -r --no-preserve=mode,ownership "$src" "$name"
rm -rf "$name/target" "$name/Cargo.lock" "$name/out"

manifest="$name/Cargo.toml"

# Repoint the intra-tree path keys at the pinned checkout:
#   path = "../../embassy-stm32"  ->  path = "/nix/store/...-source/embassy-stm32"
#
# Rewriting beats stripping. Some example deps are path-only, with no version
# at all (`embassy-executor = { path = "../../embassy-executor" }`); deleting
# the path there leaves cargo with nothing to go on and it rejects the manifest:
#   dependency (embassy-executor) specified without providing a local path,
#   Git repository, version, or workspace dependency to use
# Pointing at the same tree the patch table uses keeps everything consistent,
# so there is no risk of two copies of a crate ending up in the graph.
sed -i -E "s|path *= *\"(\.\./)+([^\"]*)\"|path = \"$embassy_src/\2\"|g" "$manifest"

# Rename the package, and drop the publish/metadata keys that only make sense
# inside embassy's own workspace.
sed -i -E "0,/^name = /s|^name = .*|name = \"$name\"|" "$manifest"
sed -i -E '/^publish = false/d' "$manifest"
# Drop embassy's internal [package.metadata.embassy*] tables -- they name build
# targets and artifact dirs that only mean something inside embassy's own CI.
# Line-wise rather than by regex: the table bodies contain '[' from their
# arrays, so "up to the next bracket" truncates mid-table and leaves a
# syntactically broken manifest behind.
awk '
    /^\[/ { skip = /^\[package\.metadata\.embassy/ }
    !skip
' "$manifest" >"$manifest.new"
mv "$manifest.new" "$manifest"

# Examples often build many binaries out of src/bin; keep them, they all work.
if [ -d "$name/src/bin" ] && [ ! -f "$name/src/main.rs" ]; then
    echo "note: this example builds several binaries from src/bin;"
    echo "      use 'cargo build --bin <name>' or 'cargo run --bin <name>'."
fi

embassy-lock "$name"

echo "created $name from embassy example '$example'"
echo "  cd $name && cargo build"
