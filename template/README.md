# An offline Rust environment

Generated from [offline-devshells](https://github.com/mayl/offline-devshells).

## First run — while you still have network

The crate set is declared in `flake.nix` under `offlineShells.myEnv.rust`, but the
lock it resolves to has to be a real, committed file: resolving needs network and
vendoring must not, so the resolution happens once and its result is checked in.
`locks/crates-io.lock` ships as a placeholder, and until it is resolved
everything except `myEnv-refresh-seed` refuses to evaluate, saying so.

A flake only sees files git tracks, so track them first:

```console
$ git init && git add -A
$ nix run .#myEnv-refresh-seed
$ git add locks/ && git commit -m "resolve the offline crate set"
$ nix build .#myEnv
```

That last command is what pulls every crate, the toolchain and the tools into the
store. After it finishes you can unplug.

## Then, network or not

```console
$ nix develop .#myEnv
$ cargo build
```

Or, once the environment is installed somewhere with no flake to develop —
`nix run .#myEnv-shell`, or `jg myEnv::shell` if you wired up the global
justfile. Same tools, same `CARGO_HOME` pointing at the vendored crates; it just
does not need anything evaluated. Give it arguments to run one command in the
environment instead of opening a shell.

## Adding a crate

Add it to `crates.<member>` in `flake.nix`, then re-resolve:

```nix
rust.modes.crates-io.crates.common.my-driver = {
  version = "0.3";
  features = [ "async" ];
};
```

```console
$ nix run .#myEnv-refresh-seed && nix build .#myEnv
```

Features matter to vendoring only where they gate *optional* dependencies, so be
generous with them — an extra feature costs a few crates in the vendor directory,
a missing one costs a project that will not resolve offline.

Members (`common` here) are resolution groups, not build units. Put crates that
could never be built together — two HALs, say — in different members.

## Putting it in a machine

`offlineShells.myEnv` carries a `nixosModule` (the entrypoints on `PATH`, the
offline bundle pinned into the closure) and a `homeModule` (`jg myEnv::shell` in
the global justfile). Combined with [vm-parts](https://github.com/mayl/vm-parts)
and [nix-global-just](https://github.com/mayl/nix-global-just) they build an
appliance. See `dev/flake-module.nix` in offline-devshells for a worked example.
