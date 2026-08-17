# Boot the machine and prove the offline environment is really there.
#
# Deliberately NOT in `checks`: the guest has to materialise the whole ~3.8 GiB
# offline closure into a disk image before it can boot, which is not something
# `nix flake check` should do. Run it explicitly:
#
#   nix build .#embassy-box-test
#
# The point is the things that only break on a real system: whether the global
# justfile reached the user's home, whether the entrypoints work outside a dev
# shell, and whether cargo can build with the network genuinely absent rather
# than merely unused.
{
  pkgs,
  machineModules,
}:
pkgs.testers.runNixOSTest {
  name = "embassy-box";

  nodes.machine = {
    imports = machineModules;

    # `virtualisation.diskSize` here is the test's scratch image, not the
    # appliance's -- it has to fit the closure the guest is handed.
    virtualisation.diskSize = 16 * 1024;
    virtualisation.memorySize = 4096;

    # There is no network in a NixOS test node anyway, but saying so makes the
    # test's claim explicit rather than incidental.
    networking.useDHCP = false;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("the global justfile reached the user"):
        machine.succeed("test -f /home/larry/.config/just/justfile")
        recipes = machine.succeed("su - larry -c 'just --global-justfile --list embassy'")
        for recipe in ["generate", "new", "from-example", "mode", "lock"]:
            assert recipe in recipes, f"{recipe} missing from the global justfile:\n{recipes}"

    with subtest("the toolchain is on PATH without entering a dev shell"):
        machine.succeed("su - larry -c 'cargo --version'")
        machine.succeed("su - larry -c 'rustc --version'")
        machine.succeed("su - larry -c 'probe-rs --version'")
        # Build scripts are host binaries and need a linker even though
        # everything else cross-compiles.
        machine.succeed("su - larry -c 'cc --version'")

    with subtest("the shell entrypoint hands over the environment, with no flake in sight"):
        machine.succeed("su - larry -c 'mkdir -p ~/work'")

        # `env` and `which`, rather than a `sh -c` that dereferences the
        # variables: `just` runs a recipe line with `sh -cu`, and a variadic
        # `{{cmd}}` is substituted into it unquoted, so a `$VAR` in the command
        # would be expanded by *that* shell -- before the entrypoint it is meant
        # for ever runs, and under `-u`, fatally.
        env = dict(
            line.split("=", 1)
            for line in machine.succeed(
                "su - larry -c 'cd ~/work && just --global-justfile embassy::shell env'"
            ).splitlines()
            if "=" in line
        )
        assert env["CARGO_HOME"] == "/home/larry/work/.cargo-home", env
        assert env["CARGO_NET_OFFLINE"] == "true", env
        assert env["EMBASSY_SRC"].startswith("/nix/store/"), env
        assert env["RUST_SRC_PATH"].startswith("/nix/store/"), env
        machine.succeed("test -f /home/larry/work/.cargo-home/config.toml")

        # And every other entrypoint came along on PATH.
        for tool in ["cargo", "probe-rs", "cc", "embassy-generate", "embassy-mode"]:
            out = machine.succeed(
                f"su - larry -c 'cd ~/work && just --global-justfile embassy::shell which {tool}'"
            ).strip()
            assert out.startswith("/nix/store/"), f"{tool}: {out}"

    with subtest("entrypoints work through the global justfile"):
        # Runs from the invocation directory, not the justfile's directory.
        machine.succeed("su - larry -c 'mkdir -p ~/work && cd ~/work && just --global-justfile embassy::mode'")
        machine.succeed("test -f /home/larry/work/.cargo-home/config.toml")
        out = machine.succeed("su - larry -c 'cd ~/work && just --global-justfile embassy::mode git'")
        assert "git" in out, out
        machine.succeed("su - larry -c 'cd ~/work && just --global-justfile embassy::mode crates-io'")

    with subtest("a project scaffolds and builds with no network"):
        machine.succeed(
            "su - larry -c 'cd ~/work && just --global-justfile embassy::generate blinky stm32f411ce'"
        )
        machine.succeed("test -f /home/larry/work/blinky/Cargo.lock")
        machine.succeed(
            "su - larry -c 'cd ~/work/blinky && CARGO_HOME=$HOME/work/.cargo-home cargo build --offline'",
            timeout=1800,
        )
        machine.succeed("test -d /home/larry/work/blinky/target")
  '';
}
