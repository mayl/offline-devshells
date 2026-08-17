#!/usr/bin/env bash
# Scaffold a project with cargo-generate from the pinned lulf/embassy-template.
#
# Of the three generators embassy's docs list, this one covers by far the most
# silicon -- every STM32 in stm32-data, the nRF52/53/54/91 families, and the
# whole RP2040/RP2350 line that cargo-embassy cannot do at all. It also emits
# correct embassy-executor features, which cargo-embassy does not.
#
# cargo-generate runs entirely from the local checkout, so this works offline.
set -euo pipefail

template="@template@"

if [ "${1:-}" = "--chips" ]; then
    sed -n 's/^choices = \[//p' "$template/cargo-generate.toml" |
        tr ',' '\n' | tr -d '" ]' | sed '/^$/d'
    exit 0
fi

if [ "$#" -lt 2 ]; then
    cat >&2 <<'USAGE'
usage: embassy-generate <project-name> <chip> [cargo-generate flags...]

  embassy-generate blinky rp2040
  embassy-generate blinky stm32g474re
  embassy-generate blinky nrf52840

Chips come from the pinned template's list; `embassy-generate --chips` prints it.
USAGE
    exit 2
fi

name="$1"
chip="$2"
shift 2

if [ -e "$name" ]; then
    echo "embassy-generate: '$name' already exists" >&2
    exit 1
fi

# cargo-generate copies the template preserving file modes, and everything in
# the Nix store is read-only -- it then fails trying to write the rendered file
# back over its own copy. Hand it a writable copy instead.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -r --no-preserve=mode,ownership "$template" "$work/template"

cargo generate --path "$work/template" --name "$name" --define "chip=$chip" --silent "$@"

# Nix owns the toolchain; the template's rustup pin would only contradict it.
rm -f "$name/rust-toolchain.toml"

embassy-lock "$name"

echo "created $name for $chip -- cd $name && cargo build"
