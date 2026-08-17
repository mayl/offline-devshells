# offline-devshells

flake-parts modules for development environments whose **entire dependency set**
is realised into the Nix store, so they keep working with the network unplugged —
and for putting one of those environments into a machine you can carry away.

```console
$ nix build .#embassy                    # 3.8 GiB: toolchain, tools, crates, sources
$ nix develop .#embassy
$ embassy-generate blinky rp2040 && cd blinky && cargo build
```

Or, without a dev shell at all — the same commands live in your global justfile:

```console
$ jg embassy::generate blinky rp2040
$ cd blinky && cargo build
```

Or, as an appliance:

```console
$ nix build .#embassy-box.vbox.file      # a VirtualBox .ova
$ nix build .#embassy-box.vm && ./result/bin/run-embassy-vm
```

## What is actually hard about this

Getting a compiler offline is easy; Nix has always done that. The hard part is
the **package registry**. `cargo build` resolves against crates.io at build time,
and a bare-metal Embassy project pulls a few hundred crates that nothing in your
flake mentions by name. So the environment has to decide, ahead of time, which
crates could possibly be wanted — and it has to do that without ever compiling
them, because the crates in question could never be built together.

The answer is a **seed workspace**: a Cargo workspace that is never compiled,
whose members exist only to name dependencies. Resolving it yields one
`Cargo.lock` spanning the union of everything you might want, and that lock
becomes a vendored directory source replacing crates.io.

This repository makes that pattern declarative. You write:

```nix
rust.modes.crates-io.crates.common = {
  heapless = { version = "0.9"; features = [ "serde" ]; };
  defmt = "1";
};
```

and the seed workspace is generated for you, extendable from any module that
wants to widen the set.

## The module

```nix
{
  imports = [ inputs.offline-devshells.flakeModules.default ];

  perSystem = { pkgs, system, ... }: {
    # The rust backend needs `pkgs.rust-bin`.
    _module.args.pkgs = import inputs.nixpkgs {
      inherit system;
      overlays = [ inputs.rust-overlay.overlays.default ];
    };

    offlineShells.myEnv = {
      packages = [ pkgs.probe-rs-tools ];
      rust = {
        version = "1.97.1";
        targets = [ "thumbv7em-none-eabihf" ];
        modes.crates-io = {
          crates.common.defmt = "1";
          lockFile = ./locks/crates-io.lock;
          lockPath = "locks/crates-io.lock";
        };
      };
    };
  };
}
```

Each shell `s` produces:

| Output | What it is |
|---|---|
| `devShells.s` | the environment |
| `packages.s` | the **offline bundle** — a `linkFarm` of every store path the environment needs |
| `packages.s-<cmd>` | one per entrypoint |
| `packages.s-vendor-<mode>`, `packages.s-seed-<mode>`, `packages.s-toolchain` | the pieces, individually |
| `apps.<cmd>` | `nix run .#<cmd>` |

and carries two modules for putting it in a machine: `nixosModule` (every package
and entrypoint on `PATH`, plus the bundle pinned into the system closure) and
`homeModule` (the entrypoints as global-just recipes). Both are per-system, so
reach them with flake-parts' `withSystem`.

Note what `nixosModule` does *not* do: it does not make `nix develop` work on the
resulting machine. The closure is there but the flake and its locked inputs are
not, so there is nothing to evaluate. On such a machine the commands are the
interface — which is the point of routing them through the global justfile.

### The generic layer

`offlineShells.<name>` knows nothing about crates or compilers. It owns:

| Option | Meaning |
|---|---|
| `packages` | on `PATH`, in the shell and in `environment.systemPackages` |
| `env` | shell fragments, expanded at run time — `CARGO_HOME = "$PWD/.cargo-home"` |
| `preamble` | shell run before any tool, in the shell hook *and* every entrypoint |
| `entrypoints.<cmd>` | the commands the environment provides |
| `bundlePaths` | extra store paths that must be present offline but are not on `PATH` |
| `banner`, `justNamespace`, `commandPrefix` | presentation |

Language support arrives as a **backend** — an option whose value contributes
back into those. `rust` is the only one so far; adding `julia` means writing
`modules/julia/` and listing it in `backendModules`, not redesigning anything.

### Entrypoints, and why they work outside the shell

Every entrypoint is a `writeShellApplication` with an **env preamble** prepended:
`env` applied with `:=` defaults rather than `=`, then `preamble`. So a script
lands in the same environment whether it was invoked from inside `nix develop` or
bare from a `just` recipe on a machine with no dev shell at all. That is the one
thing that makes the global-justfile route work.

The preamble must stay self-contained — calling another entrypoint from it would
recurse, since that one carries the same preamble. Cross-entrypoint calls are
declared instead:

```nix
entrypoints.embassy-generate.runtimeEntrypoints = [ "embassy-lock" ];
```

### Global justfile

`homeModule` renders one recipe per entrypoint under `justNamespace`:

```just
# Scaffold via cargo-generate (STM32, nRF, RP2040/RP2350)
generate name chip *flags:
    @cd "{{invocation_directory()}}" && exec /nix/store/…/bin/embassy-generate "{{name}}" "{{chip}}" {{flags}}
```

Two details are load-bearing. The `cd` is there because `just` runs a recipe with
the working directory set to the *justfile's* directory — for a global justfile
that is `~/.config/just`, which is read-only under Home Manager and nowhere near
your project. And the embedded store paths make the tools runtime references of
the rendered justfile, which is what drags the whole closure into a machine that
merely installs it.

It only *defines* `programs.globalJust` options. Import
[`nix-global-just`](https://github.com/mayl/nix-global-just)'s
`homeManagerModules.default` alongside it, which declares them.

### The rust backend

A pinned toolchain, plus one or more **modes**. A mode is one self-consistent
resolution — a crate set, its lock, an optional `[patch.crates-io]` table, and a
vendor directory. Modes cannot be merged, because cargo allows exactly one
replacement for crates.io; the generated `<prefix>-mode` command switches between
them at run time by rewriting `$CARGO_HOME/config.toml`.

| Mode option | Meaning |
|---|---|
| `crates.<member>.<crate>` | `{ version; package; features; defaultFeatures; }`, or just a version string |
| `extraManifest.<member>` | raw TOML appended inside `[dependencies]` — the escape hatch |
| `lockFile` / `lockPath` | the committed lock, read / where refresh writes it |
| `vendorHashFile` / `vendorHashPath` | present ⇒ `fetchCargoVendor` instead of `importCargoLock` |
| `patch`, `patchTree` | `[patch.crates-io]` entries, explicitly or by scanning a source tree |

`lockFile` and `lockPath` are separate because by the time anything can *read*
the lock it is a store path, and store paths are not writable.

`vendorHashFile` picks the vendorer, and the reason is git sources: a
`Cargo.lock` pins a git dependency by revision without recording a checksum, so
`importCargoLock` would need a hand-maintained hash per repository plus
hand-written `[source."git+…"]` stanzas. `fetchCargoVendor` covers all of it under
one fixed-output hash and emits a complete config. A crates.io-only lock needs
neither — the checksums are already in the lock.

**Members are resolution groups, not build units.** Put crates that could never
be built together in different ones. Four mutually exclusive HALs, each with its
own `critical-section` implementation, resolve fine — and split across members
they resolve in seconds, where cargo's resolver takes pathologically long to
unify them inside a single package.

### Widening the crate set

Resolving needs network; vendoring must not. So resolution happens once, and its
result is committed:

```console
$ nix run .#myEnv-refresh-seed        # or: jg myEnv::refresh-seed
$ git add locks/ && git commit
```

That regenerates each mode's lock from the seed workspace the module renders, and
re-learns any `vendorHashFile` by writing a hash that cannot be right, building,
and reading back the one Nix reports. Patched modes are slow — 10–15 minutes is
normal, almost all of it fetching the crates.io sparse index.

**Features matter to vendoring only insofar as they gate optional dependencies.**
Enabling one that merely flips a `cfg` changes nothing about what is fetched. So
feature lists should be generous: an extra feature costs a few more crates in the
vendor directory, a missing one costs a project that will not resolve offline at
all.

## The embassy preset

`flakeModules.embassy` is `offlineShells.embassy`, filled in — a port of
lpmTemplates' `embassy-offline` template. It closes over *this* flake's `embassy`
and `embassy-template` inputs, so a consumer gets a pinned tree without declaring
one:

```nix
imports = [
  inputs.offline-devshells.flakeModules.default
  inputs.offline-devshells.flakeModules.embassy
];
```

Two modes:

- **`crates-io`** — the published Embassy releases. ~380 crates, vendored by the
  checksums in the lock.
- **`git`** — every `embassy-*` crate in the pinned tree patched in over
  crates.io, including the six marked `publish = false`. This is the only way to
  reach chips that have no release yet: TI MSPM0, i.MX RT, MCX A. ~400 registry
  crates plus four PACs from git.

`nix flake update embassy`, or `--override-input embassy ~/my-fork`, moves the
whole git-mode environment onto a different tree.

Six entrypoints: `embassy-generate` (widest chip coverage, via cargo-generate),
`embassy-new` (via cargo-embassy), `embassy-from-example` (from the tree's own
`examples/`, the only route to MSPM0), `embassy-lock`, `embassy-mode`,
`embassy-refresh-seed`.

Two firmwares build as `checks` — an STM32F411CE from the published crates and an
MSPM0G3507 from the git tree — so `nix flake check` proves both resolutions
actually compile rather than merely evaluate.

## The appliance

`vms.embassy-box` (via [`vm-parts`](https://github.com/mayl/vm-parts)) is a
console-and-SSH NixOS machine with the embassy environment installed system-wide,
the global justfile in `larry`'s home, udev rules for the usual debug probes, and
`nix.settings.substituters = [ ]` so a stray build fails loudly instead of hanging
on a network that is not there.

```console
$ nix build .#embassy-box.vbox.file    # result *is* the .ova
$ nix build .#embassy-box.vm           # a qemu run script, for a quick look
$ nix build .#embassy-box-test         # boot it and assert the environment works
```

The boot test is deliberately outside `checks`: it materialises the whole 3.8 GiB
closure into a disk image, which `nix flake check` has no business doing.

Two things to know about the OVA:

- **Guest additions are off.** nixpkgs' `virtualbox-image.nix` turns them on
  unconditionally, and the 7.2.14 additions do not currently compile against any
  kernel in the pinned tree. That costs shared folders, clipboard and time sync —
  move code over SSH instead. It does **not** cost USB passthrough of a debug
  probe, which is a host-side feature.
- **USB passthrough needs the Extension Pack** on the host for USB 2.0/3.0
  controllers, plus a USB filter for your probe. The guest side is already set up:
  `plugdev`, and rules for CMSIS-DAP, ST-Link, J-Link, the Raspberry Pi Debug
  Probe, FTDI and TI XDS110.

## Repository layout

```
flake-module.nix              the flake-parts entry point
modules/
  offline-shells.nix          perSystem option -> flake outputs
  shell-submodule.nix         the generic layer
  entrypoint.nix              the entrypoint submodule
  rust/
    default.nix               toolchain, modes, vendoring, cargo configs
    seed.nix                  crates.<member>.<dep> -> seed workspace
    scripts/                  mode.sh, refresh-seed.sh (generated from `modes`)
presets/embassy/              the embassy environment: crates, scripts, locks, firmware
vm/                           machine.nix, test.nix
template/                     nix flake init -t github:mayl/offline-devshells
```

## Relationship to lpmTemplates

`lpmTemplates/templates/embassy-offline` is where this machinery was worked out,
and remains a fine way to start a single project. This repository is the same
thing turned into a module: the crate set became options, the entrypoints became
reachable from outside a dev shell, and the whole environment became something a
machine can be built around. The seed manifests were ported dependency for
dependency — the generated workspaces are content-identical to the hand-written
ones.
