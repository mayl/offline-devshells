#!/usr/bin/env bash
# Scaffold an Embassy project that actually builds, using only crates already
# vendored into the Nix store.
#
# `cargo embassy init` on its own is not enough:
#   * for STM32 and nRF it emits a Cargo.toml with no embassy-executor, while
#     src/main.rs and the feature list both reference it -- it does not compile;
#   * it writes an `[unstable] build-std` section, which needs a nightly
#     compiler and fetches compiler_builtins from crates.io at build time;
#   * it pins a rustup toolchain that Nix has already pinned differently;
#   * it exits 0 when it does not recognise the chip, leaving nothing behind.
set -euo pipefail

if [ "$#" -lt 2 ]; then
    cat >&2 <<'USAGE'
usage: embassy-new <project-name> <chip> [cargo-embassy flags...]

  embassy-new blinky stm32f411ce
  embassy-new blinky nrf52840 --panic-handler reset
  embassy-new blinky esp32c3
USAGE
    exit 2
fi

name="$1"
chip="$2"
shift 2

if [ -e "$name" ]; then
    echo "embassy-new: '$name' already exists" >&2
    exit 1
fi

cargo embassy init --chip "$chip" "$@" "$name" || true

if [ ! -f "$name/Cargo.toml" ]; then
    cat >&2 <<EOF
embassy-new: cargo-embassy produced no project for chip '$chip'.

The generator only knows STM32, nRF and ESP parts, and it exits 0 rather than
reporting an unknown chip. RP2040/RP2350 are not among them -- but embassy-rp,
cyw43 and the thumbv6m/thumbv8m targets are all vendored here, so writing the
project by hand builds offline just fine. See the README.
EOF
    rm -rf "$name"
    exit 1
fi

config="$name/.cargo/config.toml"

# Drop the [unstable] section, keeping any section that follows it.
awk '
    /^\[unstable\]/ { skip = 1; next }
    /^\[/           { skip = 0 }
    !skip
' "$config" >"$config.new"
mv "$config.new" "$config"

# Nix owns the toolchain; a rustup pin beside it can only contradict us.
rm -f "$name/rust-toolchain.toml"

# The manifest has to be patched textually rather than with `cargo add`: the
# generated `debug` feature already refers to `embassy-executor/defmt`, so cargo
# refuses to even parse the file until the dependency is there.
if ! grep -q '^embassy-executor' "$name/Cargo.toml"; then
    # Cortex-M unconditionally: those are the only targets in rustTargets and
    # the only HALs in the seed. cargo-embassy's other output (ESP/RISC-V) does
    # not resolve even online, so there is no second case to serve.
    #
    # The version has to match what the seed vendors
    # (nix/seed/crates/common/Cargo.toml); bumping one means bumping both.
    dep="embassy-executor = { version = \"0.10\", features = [\"platform-cortex-m\", \"executor-thread\", \"executor-interrupt\"] }"

    awk -v dep="$dep" '
        { print }
        /^\[dependencies\]$/ && !inserted { print dep; inserted = 1 }
    ' "$name/Cargo.toml" >"$name/Cargo.toml.new"
    mv "$name/Cargo.toml.new" "$name/Cargo.toml"

    if ! grep -q '^embassy-executor' "$name/Cargo.toml"; then
        echo "embassy-new: could not find a [dependencies] table to patch" >&2
        exit 1
    fi
fi

# Re-resolve so the lock names only crates that exist in the vendor directory.
rm -f "$name/Cargo.lock"
embassy-lock "$name"

echo "created $name -- cd $name && cargo build"
