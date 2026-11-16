# offline-devshells

flake-parts modules for development environments whose **entire dependency set**
is realised into the Nix store, so they keep working with the network unplugged —
and for putting one of those environments into a machine you can carry away.

```console
$ nix build .#embassy                    # 3.8 GiB: toolchain, tools, crates, sources
$ nix develop .#embassy
$ embassy-generate blinky rp2040 && cd blinky && cargo build
```

Or, on a machine with no flake to develop — one recipe in your global justfile
gets you in, and from there the tools are just tools:

```console
$ jg embassy::shell                      # or `embassy-shell`
$ embassy-generate blinky rp2040
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

and carries two modules for putting it in a machine: `nixosModule` (the
entrypoints on `PATH`, plus the bundle pinned into the system closure) and
`homeModule` (the shell entrypoint as a global-just recipe). Both are per-system,
so reach them with flake-parts' `withSystem`.

`nixosModule` installs the entrypoints and deliberately **not** `packages`. An
entrypoint sources the environment itself, so it is correct wherever it is run
from; a bare tool is not. A `cargo` on `PATH` without `CARGO_HOME` pointing at
the vendored config is a compiler that *looks* configured, resolves against the
user's real cargo home, finds nothing, and reaches for the network — the one
failure this whole thing exists to rule out. Better that a login shell have no
`cargo` at all and an obvious way to get one. If you want the raw tools
system-wide anyway, they are one line away:

```nix
environment.systemPackages = config.offlineShells.embassy.packages;
```

It does not make `nix develop` work on the resulting machine either: the closure
is there but the flake and its locked inputs are not, so there is nothing to
evaluate. `<name>-shell` is what replaces it.

### The generic layer

`offlineShells.<name>` knows nothing about crates or compilers. It owns:

| Option | Meaning |
|---|---|
| `packages` | on `PATH` inside the environment — the dev shell and `<prefix>-shell`, not system-wide |
| `env` | shell fragments, expanded at run time — `CARGO_HOME = "$PWD/.cargo-home"` |
| `preamble` | shell run before any tool, in the shell hook *and* every entrypoint; must be idempotent |
| `entrypoints.<cmd>` | the commands the environment provides |
| `bundlePaths` | extra store paths that must be present offline but are not on `PATH` |
| `banner`, `justNamespace`, `commandPrefix` | presentation |

Language support arrives as a **backend** — an option whose value contributes
back into those. `rust` is the only one so far; adding `julia` means writing
`modules/julia/` and listing it in `backendModules`, not redesigning anything.

### One environment, several ways in

`env` and `preamble` are rendered **once**, into a single `env.bash` in the store,
and everything sources that same file — the dev shell's hook, every entrypoint,
and you, from an `.envrc` or a CI script (`offlineShells.<name>.envFile`, also
`env.bash` inside the offline bundle):

```bash
if [ -z "${OFFLINE_DEVSHELL_embassy:-}" ]; then
    export OFFLINE_DEVSHELL_embassy=1
    export CARGO_HOME="$PWD/.cargo-home"
    export CARGO_NET_OFFLINE="true"
    ...
fi

mkdir -p "$CARGO_HOME"          # preamble: outside the guard, so it re-runs
...
```

This is [numtide/devshell](https://github.com/numtide/devshell)'s idea, and the
reason to copy it is that the alternative — one rendering for the shell hook,
another for the scripts — drifts, and the drift is invisible until a command
behaves differently inside the shell than outside it. `nix develop` is not the
privileged route here; it just sources the file like everyone else.

The guard is why a script lands in the same environment whether it was invoked
from inside `nix develop` or bare from a `just` recipe on a machine with no dev
shell at all. Entering fresh, these values win over whatever the caller had set —
a stray `CARGO_HOME` in someone's profile must not be able to point an *offline*
environment at a cargo home with no vendored sources in it. A command run from
*within* the environment inherits what is already established instead of
recomputing it, which matters because the useful values are `$PWD`-relative:
recomputing in a subdirectory would move `CARGO_HOME` and quietly abandon the
mode the user had selected.

The `preamble` sits outside the guard because it has to be idempotent anyway, and
re-running it recreates state deleted between two commands.

The preamble must stay self-contained — calling another entrypoint from it would
recurse, since that one carries the same preamble. Cross-entrypoint calls are
declared instead:

```nix
entrypoints.embassy-generate.runtimeEntrypoints = [ "embassy-lock" ];
```

One entrypoint is generated for you: `<commandPrefix>-shell`, which puts every
package and every other entrypoint on `PATH`, applies the environment, and execs
`$SHELL` — or runs its arguments inside the environment instead.

```console
$ jg embassy::shell                      # a shell with everything set up
$ jg embassy::shell cargo build          # or just run one thing in it
```

### One recipe, not one per command

`just.enable` defaults to **false**, and the shell entrypoint is the only thing
that turns it on for itself.

A recipe is worth having for a command you run from *outside* the environment.
Once you are inside, every entrypoint is already on `PATH`, so `jg ns::foo` is a
longer way to write `foo` — and a worse one: `just` runs recipe lines through an
extra `sh -cu`, and a variadic parameter is substituted into that line unquoted,
so a `$VAR` in your arguments is expanded by *that* shell before the command ever
sees it, fatally under `-u`. Compare:

```console
$ jg embassy::shell sh -c "echo $CARGO_HOME"    # expands too early; fails
$ embassy-shell sh -c 'echo "$CARGO_HOME"'      # no extra layer
```

So: one way in, then ordinary commands. Set `just.enable = true` on an entrypoint
if you want a recipe for it anyway.

This is what `nix develop` cannot be once an environment has been *installed*
rather than evaluated: on the appliance there is no flake and no lock, so the
"drop me in it" gesture has to be an ordinary program. Set `enterCommand = null`
to suppress it, or point it at another name.

### Global justfile

`homeModule` renders one recipe per entrypoint that sets `just.enable` — by
default only the shell entrypoint — into
`programs.globalJust.namespaces.<justNamespace>`, which nix-global-just writes to
`~/.config/just/<namespace>.just` and pulls in with `mod <namespace>`:

```just
# Enter a shell with the embassy environment on PATH
[no-cd]
shell *cmd:
    @exec /nix/store/…/bin/embassy-shell {{cmd}}
```

Two details are load-bearing. `[no-cd]` is there because `just` otherwise runs a
recipe with the working directory set to the *justfile's* directory — for a
global justfile that is `~/.config/just`, which is read-only under Home Manager
and nowhere near your project. And the embedded store paths make the tools
runtime references of the rendered justfile, which is what drags the whole
closure into a machine that merely installs it.

It only *defines* `programs.globalJust` options. Import
[`nix-global-just`](https://github.com/mayl/nix-global-just)'s
`homeManagerModules.default` alongside it, which declares them. Its `jg` command
is a fish function (written only when Home Manager's `programs.fish.enable` is
on) and a bash/zsh alias.

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
$ nix run .#myEnv-refresh-seed        # or, inside the environment: myEnv-refresh-seed
$ git add locks/ && git commit
```

That regenerates each mode's lock from the seed workspace the module renders, and
re-learns any `vendorHashFile` by writing a hash that cannot be right, building,
and reading back the one Nix reports (with your own `nix` — it is not pinned). It
is all or nothing: every mode is resolved before any lock is written, and if a
hash cannot be learned (the build fails for any other reason), every lock and
hash file is put back and the build output shown. Patched modes are slow — 10–15 minutes is normal, almost all of it
fetching the crates.io sparse index.

It is the one command that works before anything is resolved: a placeholder lock
(`version = 4` and no packages) makes every other output refuse to evaluate with
a message pointing here. `lockPath` must name the same file as `lockFile`, and
`vendorHashPath` as `vendorHashFile`; evaluation checks that.

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
imports = [ inputs.offline-devshells.flakeModules.embassy ];
```

(It imports `flakeModules.default` itself; listing both is harmless.)

Two modes:

- **`crates-io`** — the published Embassy releases. ~380 crates, vendored by the
  checksums in the lock.
- **`git`** — every `embassy-*` crate in the pinned tree patched in over
  crates.io, including the six marked `publish = false`. This is the only way to
  reach chips that have no release yet: TI MSPM0, i.MX RT, MCX A. ~400 registry
  crates plus four PACs from git.

The git mode's lock and vendor hash are resolved against the pinned tree. A
different tree — `nix flake update embassy`, `--override-input embassy
~/my-fork` — generally pulls different registry crates and git revisions, so it
needs those re-resolved (`embassy-refresh-seed`) before git mode builds offline.
In this repository that is the "Bumping" routine below; from another flake, see
[Changing the preset from your own flake](#changing-the-preset-from-your-own-flake).

Six commands. Only the first is also a `jg` recipe — see
[One recipe, not one per command](#one-recipe-not-one-per-command).

| Command | What it does |
|---|---|
| `embassy-shell [cmd…]` — also `jg embassy::shell` | enter the environment, or run one command in it |
| `embassy-generate <name> <chip>` | scaffold via cargo-generate (STM32, nRF, RP2040/RP2350) |
| `embassy-from-example <example> [name]` | scaffold from the tree's own `examples/` — the only route to MSPM0 |
| `embassy-lock [dir]` | resolve a project against the vendored crate set |
| `embassy-mode [crates-io\|git]` | switch crate sets, or report the active one |
| `embassy-refresh-seed [root]` | re-resolve both crate sets (needs network) |

The environment it hands over:

| Variable | Points at |
|---|---|
| `CARGO_HOME` | `$PWD/.cargo-home` — its `config.toml` is what replaces crates.io with the vendor directory |
| `CARGO_NET_OFFLINE` | `true`, so a project-local cargo config cannot quietly re-enable the network |
| `RUST_SRC_PATH` | the pinned toolchain's `rust-src`, for rust-analyzer |
| `EMBASSY_SRC`, `EMBASSY_TEMPLATE_SRC` | the pinned trees in the store, for grepping the HAL you are building against |

Set on entry, and inherited rather than recomputed by anything run from within —
see [One environment, several ways in](#one-environment-several-ways-in).

Two firmwares build as `checks` — an STM32F411CE from the published crates and an
MSPM0G3507 from the git tree — so `nix flake check` proves both resolutions
actually compile rather than merely evaluate. Neither commits a `Cargo.lock`:
each resolves one at build time the way `embassy-lock` does for your project.
(Importing the preset brings these checks into your flake too, so your `nix
flake check` builds them.)

### Changing the preset from your own flake

Used unchanged, the preset needs nothing from you: its locks live in
offline-devshells and match its pinned tree. To widen its crate set
(`offlineShells.embassy.rust.modes.<mode>.crates…`) or put git mode on another
embassy tree, the locks have to live in *your* repository, because
`embassy-refresh-seed` rewrites them:

```console
$ src=$(nix eval --raw --impure --expr \
    '(builtins.getFlake (toString ./.)).inputs.offline-devshells.outPath')
$ mkdir -p locks/embassy
$ install -m 0644 "$src"/presets/embassy/locks/* locks/embassy/
```

```nix
embassyPreset.locksDir = ./locks/embassy;
# embassyPreset.locksPath = "locks/embassy";   # derived; set it only if the flake is not the repo root
```

```console
$ git add locks/embassy
$ nix run .#embassy-refresh-seed        # with network
$ git add locks/embassy && git commit
```

Run against the preset's own locks from another flake, `embassy-refresh-seed`
stops and says so rather than writing somewhere unexpected.

## The appliance

`vms.embassy-box` (via [`vm-parts`](https://github.com/mayl/vm-parts)) is a
console-and-SSH NixOS machine with the embassy entrypoints on `PATH`, the global
justfile in `larry`'s home, udev rules for the usual debug probes, and
`nix.settings.substituters = [ ]` so a stray build fails loudly instead of hanging
on a network that is not there.

Logging in gives you the `embassy-*` commands but no bare `cargo` — that lives
inside the environment, for the reason above. The MOTD says so:

```console
$ ssh embassy
  embassy-shell                    enter the environment (cargo, probe-rs, gdb)
  embassy-shell <cmd>              or run one command in it
  jg embassy::shell                the same, from the global justfile

$ embassy-generate blinky stm32f411ce     # entrypoints work as they are
$ embassy-shell
$ cd blinky && cargo build                # tools are tools, once you are in
```

```console
$ nix build .#embassy-box.vbox.file    # result *is* the .ova
$ nix build .#embassy-box.vm           # a qemu run script, for a quick look
$ nix build .#embassy-box-test         # boot it and assert the environment works
```

The boot test is deliberately outside `checks`: it materialises the whole 3.8 GiB
closure into a disk image, which `nix flake check` has no business doing.

The appliance lives in a flake-parts *partition* (`dev/`): its inputs —
vm-parts, Home Manager, nix-global-just — are declared and locked in
`dev/flake.nix`, so a flake that merely imports these modules never locks or
fetches them. The machine is still evaluated against the root `nixpkgs`, so the
environment in the image is exactly `nix build .#embassy`.

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
  versions.nix, versions.json where the embassy crates' versions come from
  bump/                       embassy-bump, this repository's one-command bump
dev/                          the appliance's partition: its inputs, and vms.embassy-box
vm/                           machine.nix, test.nix
tests/                        module tests, embassy version derivation, embassy-bump (all in `checks`)
template/                     nix flake init -t github:mayl/offline-devshells
```

## Bumping

Nothing here moves on its own; `flake.lock` and `dev/flake.lock` pin everything.

**nixpkgs / flake-parts / rust-overlay** — `nix flake update <input>`. Keep
`dev/flake.lock`'s `dev-nixpkgs` and `dev-flake-parts` at the same revisions
(`nix flake update --flake ./dev dev-nixpkgs dev-flake-parts`, then check the
revs match): they only deduplicate that lock, but matching revisions cost
nothing to fetch. Re-check the VirtualBox guest-additions `mkForce` in
`dev/flake-module.nix` on every nixpkgs bump.

**vm-parts / Home Manager / nix-global-just** — `nix flake update --flake ./dev
<input>`.

**embassy and Rust** — one command, with network:

```console
$ nix run .#embassy-bump            # 15–30 minutes; see --help
$ git add -A && git commit
```

It moves the `embassy` input to current main and brings everything that depends
on it along:

1. **Checks `crates.nix` against the new tree.** Embassy's own crates are named
   there without versions; a crate the tree no longer has stops the bump here,
   since what replaces it is a human's call.
2. **Derives the versions.** Git mode reads each crate's version from the pinned
   tree at evaluation time. Crates-io mode uses the newest release on crates.io,
   which the bump looks up and records in `presets/embassy/versions.json`; when a
   release crosses a major, the previous one stays seeded beside it as
   `<name>-prev`, so existing projects keep resolving offline. Requested features
   a version no longer has are dropped and listed (see
   [presets/embassy/versions.nix](presets/embassy/versions.nix)).
3. **Moves Rust** to the toolchain embassy's `rust-toolchain.toml` names (never
   down), updating `rust-overlay` only if it does not have that version yet. The
   version lives in `versions.json` too.
4. **Re-resolves both crate sets** (`embassy-refresh-seed`). The crates.io lock
   moves to current releases of everything in it, not only embassy.
5. **Rewrites the versions that are written down** — the two example firmwares'
   `Cargo.toml` and `template/flake.nix` — wherever a requirement no longer holds.
   The `embassy-manifests-in-sync` check refuses a checked-in copy that disagrees.
6. **Proves it:** `nix flake check` (both firmwares) and `nix build .#embassy`.

If any step fails, every file it touched is put back and it says what broke and
what to decide: a firmware that no longer compiles is an upstream API change to
port in `presets/embassy/firmware*/src`; a feature or crate cargo cannot find
needs `crates.nix` or a firmware `Cargo.toml` changed. `--keep-on-failure` leaves
the bumped tree in place to fix by hand. `--rev <rev>` pins embassy somewhere
other than main.

CI's weekly bump workflow runs exactly this command and opens a PR with its
summary; see `.github/workflows/`.

**Rust, by hand** — `embassy-bump` handles the usual case. To pin a different
version, set `rust` in `presets/embassy/versions.json` (`rust-overlay` must
provide it) and re-run the bump, which carries it into `template/flake.nix`. The
README and the examples in `modules/offline-shells.nix` / `flake-module.nix`
name a version too, as plain illustrations of the option.

## Relationship to lpmTemplates

`lpmTemplates/templates/embassy-offline` is where this machinery was worked out,
and remains a fine way to start a single project. This repository is the same
thing turned into a module: the crate set became options, the entrypoints became
reachable from outside a dev shell, and the whole environment became something a
machine can be built around. The seed manifests were ported dependency for
dependency — the generated workspaces are content-identical to the hand-written
ones.
