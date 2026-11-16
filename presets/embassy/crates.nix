# The offline crate set, as structured options.
#
# Ported from the hand-written seed workspaces of lpmTemplates' `embassy-offline`
# template. The reasoning that used to live in those `Cargo.toml` comments is
# load-bearing, so it is preserved here rather than lost in the translation.
#
# The single most important thing to know: **features matter to vendoring only
# insofar as they gate optional dependencies**. Enabling a feature that merely
# flips a `cfg` changes nothing about what gets fetched. So the feature lists
# below are deliberately generous -- an extra feature costs a few more crates in
# the vendor directory, a missing one costs a project that will not resolve
# offline at all.
#
# Crates that embassy itself publishes -- everything living in the embassy tree:
# `embassy-*`, `cyw43`, `cyw43-pio` -- are named here *without* a version. Their
# versions are derived (./versions.nix): from the pinned tree in git mode, from
# ./versions.json (the newest crates.io release, kept current by `embassy-bump`)
# in crates-io mode. So a bump never needs a version edited here. An entry that
# does give one (`embassy-executor-09`) is a deliberately seeded older major.
#
# To widen the set: add an attribute, run `embassy-refresh-seed` with network
# (or `embassy-bump`, for a new crate from the embassy tree), and commit the
# updated lock.
{ lib }:
let
  # Chip-independent half: the executor, the sync/time primitives, the
  # embedded-hal traits, and the usual no_std utility crates.
  common = {
    # Cortex-M runtime
    cortex-m = {
      version = "0.7";
      features = [
        "inline-asm"
        "critical-section-single-core"
      ];
    };
    cortex-m-rt = "0.7";
    critical-section = "1";
    portable-atomic = {
      version = "1";
      features = [ "critical-section" ];
    };

    # Embassy core.
    #
    # 0.10 renamed the `arch-*` features to `platform-*`. 0.9 is seeded beside
    # the current major so that a project pinned to it still resolves offline.
    embassy-executor = {
      features = [
        "platform-cortex-m"
        "executor-thread"
        "executor-interrupt"
        "defmt"
      ];
    };
    embassy-executor-09 = {
      package = "embassy-executor";
      version = "0.9";
      features = [
        "arch-cortex-m"
        "executor-thread"
        "executor-interrupt"
        "defmt"
      ];
    };
    embassy-time = {
      features = [
        "defmt"
        "defmt-timestamp-uptime"
      ];
    };
    embassy-sync = {
      features = [ "defmt" ];
    };
    embassy-futures = {
      features = [ "defmt" ];
    };
    embassy-embedded-hal = {
      features = [ "defmt" ];
    };

    # Embassy networking / USB stacks
    embassy-usb = {
      features = [ "defmt" ];
    };
    embassy-usb-logger = { };
    embassy-net = {
      features = [
        "defmt"
        "tcp"
        "udp"
        "dns"
        "dhcpv4"
        "medium-ethernet"
        # Renamed `ipv6` when embassy-net moved off smoltcp (late 2026). Both
        # are listed; each mode drops the one its version lacks.
        "proto-ipv6"
        "ipv6"
      ];
    };
    embassy-net-driver-channel = { };

    # Logging / panic
    defmt = "1";
    defmt-rtt = "1";
    panic-probe = {
      version = "1";
      features = [ "print-defmt" ];
    };
    panic-halt = "1";
    panic-reset = "0.1";
    log = "0.4";

    # embedded-hal ecosystem
    embedded-hal = "1";
    embedded-hal-async = "1";
    embedded-hal-bus = {
      version = "0.3";
      features = [ "async" ];
    };
    embedded-io = "0.7";
    embedded-io-async = "0.7";
    embedded-storage = "0.3";
    embedded-storage-async = "0.4";
    nb = "1";

    # no_std utilities
    heapless = {
      version = "0.9";
      features = [ "serde" ];
    };
    static_cell = "2";
    bitflags = "2";
    byteorder = {
      version = "1";
      defaultFeatures = false;
    };
    fixed = "1";
    libm = "0.2";
    micromath = "2";
    futures-util = {
      version = "0.3";
      defaultFeatures = false;
      features = [ "async-await" ];
    };
    rand = {
      version = "0.10";
      defaultFeatures = false;
    };
    rand_core = "0.10";
    serde = {
      version = "1";
      defaultFeatures = false;
      features = [ "derive" ];
    };
    postcard = "1";

    # Older majors that embassy's examples still pin. Cargo keeps them side by
    # side with the current ones, and vendoring both is what lets
    # `embassy-from-example` output resolve offline.
    embedded-hal-bus-01 = {
      package = "embedded-hal-bus";
      version = "0.1";
    };
    embedded-hal-bus-02 = {
      package = "embedded-hal-bus";
      version = "0.2";
    };
    rand-09 = {
      package = "rand";
      version = "0.9";
      defaultFeatures = false;
    };
    embedded-nal-async-08 = {
      package = "embedded-nal-async";
      version = "0.8";
    };
  };

  # Embassy's out-of-tree network and USB drivers. Git mode only: the crates
  # themselves come from the patch table, but their registry dependencies have to
  # be in the vendor directory. A crate that leaves the tree stops evaluation
  # (see ./versions.nix) rather than silently resolving from crates.io.
  commonGitExtra = {
    embassy-net-wiznet = { };
    embassy-net-adin1110 = { };
    embassy-net-enc28j60 = { };
    embassy-net-esp-hosted = { };
    embassy-net-ppp = { };
    # (embassy-usb-host was folded into embassy-usb as its `host` feature, on by
    # default, in late 2026; embassy-usb above covers it.)
    embassy-usb-dfu = {
      features = [ "dfu" ];
    };
  };

  # The non-embassy crates embassy's own examples/ pull in, so that
  # `embassy-from-example` produces something that actually builds offline. The
  # list came from scanning all 83 example manifests and diffing against the rest
  # of the seed -- `panic-semihosting` alone is used by nine of them.
  #
  # Deliberately not included:
  #   * crates for architectures this environment ships no rust-std for (riscv*,
  #     aarch32*, arm-gic) and the i.MX RT boot generators;
  #   * the std/wasm-only examples (clap, nix, env_logger, wasm-bindgen, web-sys,
  #     ratatui/mousefood);
  #   * crates the examples themselves take from git rather than crates.io
  #     (assign-resources, reqwless, defmt-serial, embedded-fatfs,
  #     block-device-adapters) -- vendoring those would mean pinning each of those
  #     repositories as well.
  # Examples needing any of the above will not resolve offline.
  examples = {
    # panic handlers and semihosting
    panic-semihosting = "0.6";
    semihosting = "0.1";
    defmt-semihosting = "0.3";

    # display / graphics
    embedded-graphics = "0.8";
    embedded-graphics-core = "0.4";
    display-interface = "0.5";
    display-interface-spi = "0.5";
    mipidsi = "0.8";
    tinybmp = "0.5";
    smart-leds = "0.3";

    # storage
    embedded-sdmmc = "0.9";

    # crypto / checksums
    hmac = "0.12";
    sha2 = {
      version = "0.10";
      defaultFeatures = false;
    };
    aes-gcm = {
      version = "0.10";
      defaultFeatures = false;
      features = [ "aes" ];
    };
    crc = "3";
    hex-literal = "1";

    # misc no_std helpers used across the examples
    grounded = "0.2";
    fixed-macro = "1.2";
    serde-json-core = "0.5";
    byte-slice-cast = "1.2";
    num-integer = {
      version = "0.1";
      defaultFeatures = false;
    };
    microfft = "0.5";
    embedded-alloc = "0.7";
    embedded-io-adapters = "0.7";
    embedded-mcu-hal = "0.3";

    # RTIC, used by a few of the nRF/STM32 examples
    rtic = {
      version = "2";
      features = [ "thumbv7-backend" ];
    };
    rtic-monotonics = "2.1";
    rtos-trace = "0.2";
    systemview-target = "0.2";

    # device drivers the examples demonstrate
    stm32wb-hci = "0.18";
    tb6612fng = "1";
    tmp108 = "0.4";
    pca9535 = "2";
    is31fl3743b-driver = "0.1";

    # Older/newer majors pinned by individual examples.
    embedded-sdmmc-07 = {
      package = "embedded-sdmmc";
      version = "0.7";
    };
    smart-leds-04 = {
      package = "smart-leds";
      version = "0.4";
    };
    tinybmp-06 = {
      package = "tinybmp";
      version = "0.6";
    };
    usbd-hid = "0.10";
    usbd-hid-09 = {
      package = "usbd-hid";
      version = "0.9";
    };
    stm32-fmc = "0.4";
    stm32-fmc-03 = {
      package = "stm32-fmc";
      version = "0.3";
    };
    embedded-nal-async = "0.9";
  };

  # One chip feature is NOT enough here. A G4 or H7 part pulls `stm32-hrtim`,
  # which an F4 never does, and a directory source has to be able to answer for
  # it or resolution fails outright with "no matching package named
  # `stm32-hrtim`".
  stm32 = {
    embassy-stm32 = {
      features = [
        "stm32f411ce"
        "memory-x"
        "time-driver-any"
        "time"
        "exti"
        "unstable-pac"
        "defmt"
        "log"
        "chrono"
        "stm32-hrtim"
      ];
    };

    # stm32-hrtim carries its own per-family optional PACs. A G4 or H7 chip
    # feature in embassy-stm32 activates `stm32-hrtim/stm32g474` etc., which in
    # turn wants `dep:stm32g4` -- so it is depended on directly here with every
    # family feature on, otherwise a G474 project dies with "no matching package
    # named stm32g4".
    stm32-hrtim = {
      version = "0.2";
      features = [
        "stm32f3"
        "stm32g4"
        "stm32h7"
      ];
    };
  };

  nrf = {
    embassy-nrf = {
      features = [
        "nrf52840"
        "time-driver-rtc1"
        "time"
        "gpiote"
        "unstable-pac"
        "defmt"
        "log"
      ];
    };
  };

  # lulf/embassy-template still generates `embassy-nrf = "0.9"`, so that major is
  # seeded alongside current. Crates-io mode only: the git tree carries a single
  # version and a ^0.9 requirement cannot be satisfied by a patch.
  nrfCratesIoExtra = {
    embassy-nrf-09 = {
      package = "embassy-nrf";
      version = "0.9";
      features = [
        "nrf52840"
        "time-driver-rtc1"
        "time"
        "gpiote"
        "unstable-pac"
        "defmt"
      ];
    };
  };

  # cyw43 is the Pico W wifi/BT chip driver; it is the main reason to seed the
  # RP2040 graph even if you only ever build for STM32.
  rp = {
    embassy-rp = {
      features = [
        "rp2040"
        "time-driver"
        "critical-section-impl"
        "unstable-pac"
        "defmt"
        "log"
        "chrono"
        "binary-info"
        "executor-thread"
        "executor-interrupt"
      ];
    };
    cyw43 = {
      features = [
        "defmt"
        "firmware-logs"
      ];
    };
    cyw43-pio = {
      features = [ "defmt" ];
    };
  };

  # Likewise for the template's `embassy-rp = "0.9"`.
  rpCratesIoExtra = {
    embassy-rp-09 = {
      package = "embassy-rp";
      version = "0.9";
      features = [
        "rp2040"
        "time-driver"
        "critical-section-impl"
        "unstable-pac"
        "defmt"
      ];
    };
  };

  # Git mode only. `embassy-mspm0` is `publish = false` in the tree and the
  # crates.io name holds nothing but an empty 0.0.0 placeholder, so the tree's
  # version (0.1.0 at the time of writing) can only ever be satisfied by the
  # patch table -- which cargo is happy to do, even for a version the registry
  # has never seen.
  #
  # Pulls `mspm0-metapac` transitively, which the tree takes from a git tag.
  mspm0 = {
    embassy-mspm0 = {
      features = [
        "mspm0g3507pm"
        "rt"
        "time-driver-any"
        "defmt"
        "log"
        "unstable-pac"
      ];
    };
  };
in
{
  cratesIo = {
    inherit common examples stm32;
    nrf = nrf // nrfCratesIoExtra;
    rp = rp // rpCratesIoExtra;
  };

  git = {
    inherit
      examples
      stm32
      nrf
      rp
      mspm0
      ;
    common = common // commonGitExtra;
  };
}
