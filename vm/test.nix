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

    with subtest("the global justfile reached the user, with the one recipe worth having"):
        machine.succeed("test -f /home/larry/.config/just/justfile")
        recipes = machine.succeed("su - larry -c 'just --global-justfile --list embassy'")
        assert "shell" in recipes, recipes
        # The scaffolders are commands, not recipes: from inside the environment
        # `jg embassy::generate` is a longer way to write `embassy-generate`.
        for gone in ["generate", "new", "from-example", "refresh-seed"]:
            assert gone not in recipes, f"{gone} should not be a recipe:\n{recipes}"

    with subtest("entrypoints work from a bare login shell; bare tools are not there to misuse"):
        machine.succeed("su - larry -c 'embassy-mode --help'")
        machine.succeed("su - larry -c 'command -v embassy-generate'")
        # The point of keeping `packages` out of systemPackages: a `cargo` on
        # PATH without CARGO_HOME would resolve against ~/.cargo and reach for
        # the network, which is the one thing this box must not do.
        machine.fail("su - larry -c 'command -v cargo'")
        machine.fail("su - larry -c 'command -v probe-rs'")

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

    with subtest("commands act on the invocation directory, not the justfile's"):
        # `jg` runs the recipe with the working directory set to
        # ~/.config/just unless the generated body corrects for it.
        machine.succeed("su - larry -c 'mkdir -p ~/elsewhere'")
        machine.succeed(
            "su - larry -c 'cd ~/elsewhere && just --global-justfile embassy::shell true'"
        )
        machine.succeed("test -d /home/larry/elsewhere/.cargo-home")
        machine.fail("test -e /home/larry/.config/just/.cargo-home")

        # And the mode a user selects sticks, without a recipe of its own.
        out = machine.succeed("su - larry -c 'cd ~/work && embassy-mode git'")
        assert "git" in out, out
        assert machine.succeed("su - larry -c 'cd ~/work && embassy-mode current'").strip() == "git"
        machine.succeed("su - larry -c 'cd ~/work && embassy-mode crates-io'")

    with subtest("a project scaffolds and builds with no network"):
        # The whole workflow as a user would type it: enter once, then use the
        # tools normally. No CARGO_HOME passed in by hand -- if the environment
        # did not carry it, this build would resolve against ~/.cargo and fail.
        machine.succeed("su - larry -c 'cd ~/work && embassy-generate blinky stm32f411ce'")
        machine.succeed("test -f /home/larry/work/blinky/Cargo.lock")
        machine.succeed(
            "su - larry -c 'cd ~/work && embassy-shell sh -c \"cd blinky && cargo build\"'",
            timeout=1800,
        )
        machine.succeed("test -d /home/larry/work/blinky/target")
  '';
}
