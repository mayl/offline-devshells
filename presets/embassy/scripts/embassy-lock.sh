#!/usr/bin/env bash
# Produce a Cargo.lock for a project without touching the network.
#
# In crates-io mode this is just `cargo generate-lockfile --offline`.
#
# Git mode needs a detour. Several crates in the tree come from git rather than
# crates.io (mspm0-metapac, rp-pac, stm32-metapac, xarxa), and cargo flatly
# refuses to resolve a *vendored* git source from scratch:
#
#   the source git+https://... requires a lock file to be present first
#   before it can be used against vendored source code
#
# Seeding the project with nix/seed-git/Cargo.lock supplies those pins. That
# lock is a superset -- the first `cargo build` prunes it to just what the
# project uses (252 entries down to ~115 for a blinky). Note that `cargo
# generate-lockfile` re-resolves and so hits the same wall; only `cargo build`
# and friends will prune, which is why this does not run it afterwards.
set -euo pipefail

seed_lock="@gitSeedLock@"

dir="${1:-.}"

if [ ! -f "$dir/Cargo.toml" ]; then
    echo "embassy-lock: no Cargo.toml in '$dir'" >&2
    exit 1
fi

if [ "$(embassy-mode current)" = "git" ]; then
    install -m 0644 "$seed_lock" "$dir/Cargo.lock"
    echo "embassy-lock: seeded $dir/Cargo.lock from the git-mode lock (cargo will prune it on first build)"
else
    (cd "$dir" && cargo generate-lockfile --offline)
fi
