# The embassy preset's version derivation (presets/embassy/versions.nix), at
# evaluation time, against a two-crate fixture tree -- no network, no embassy.
#
# What `embassy-bump` relies on to stay hands-off: versions come from the tree
# and versions.json, never from crates.nix; a feature upstream dropped is
# dropped and reported, not fatal; a crate upstream removed *is* fatal; a major
# crossed keeps the previous one seeded; and the manifest rewrite touches only
# requirements that no longer hold.
{ pkgs, lib }:
let
  pinned = {
    rust = "1.2.3";
    cratesIo = {
      embassy-foo = {
        version = "0.4.0";
        unavailable = [ "gone" ];
        previous = {
          version = "0.3.5";
        };
      };
      embassy-bar.version = "1.3.0";
    };
    git.embassy-foo.unavailable = [ "gone" ];
  };

  v = import ../presets/embassy/versions.nix {
    inherit lib pinned;
    embassySrc = ./fixtures/embassy-tree;
  };

  crates = {
    git.m = {
      embassy-foo.features = [
        "defmt"
        "gone"
      ];
      embassy-bar = { };
      heapless = "0.9";
    };
    cratesIo.m = {
      embassy-foo.features = [
        "defmt"
        "gone"
      ];
      embassy-bar = { };
    };
  };
  r = v.resolve crates;

  # A hand-written entry for the previous major suppresses the automatic one.
  r2 = v.resolve {
    git = { };
    cratesIo.m = {
      embassy-foo = { };
      embassy-foo-03 = {
        package = "embassy-foo";
        version = "0.3";
      };
    };
  };

  fails = x: !(builtins.tryEval (builtins.deepSeq x x)).success;

  cargo = ''
    [package]
    name = "fw"
    version = "0.1.0"

    [dependencies]
    embassy-foo = { version = "0.3", features = ["defmt"] }
    embassy-bar = "1.1.0"
    heapless = "0.9"
  '';
  nix = ''
    rust = {
      version = "1.0.0";
      crates.common = {
        embassy-foo = {
          version = "0.4";
          features = [ ];
        };
        embassy-bar = "0.9";
        other = {
          version = "0.4";
        };
      };
    };
  '';

  assertions = [
    {
      name = "git mode takes the tree's version, from a TOML 1.1 manifest";
      ok = r.git.m.embassy-foo.version == "0.3.1" && r.git.m.embassy-bar.version == "1.2.0";
    }
    {
      name = "an entry with its own version is passed through";
      ok = r.git.m.heapless == "0.9";
    }
    {
      name = "crates-io mode takes versions.json's version";
      ok = r.cratesIo.m.embassy-foo.version == "0.4.0" && r.cratesIo.m.embassy-bar.version == "1.3.0";
    }
    {
      name = "an unavailable feature is dropped, in both modes, and reported";
      ok =
        r.git.m.embassy-foo.features == [ "defmt" ]
        && r.cratesIo.m.embassy-foo.features == [ "defmt" ]
        && lib.length r.dropped == 2
        && lib.all (d: d.feature == "gone" && d.crate == "embassy-foo") r.dropped;
    }
    {
      name = "the previous major is seeded beside a new one";
      ok =
        r.cratesIo.m.embassy-foo-prev.version == "0.3.5"
        && r.cratesIo.m.embassy-foo-prev.package == "embassy-foo"
        && !(r.git.m ? embassy-foo-prev);
    }
    {
      name = "...unless a hand-written entry already seeds that major";
      ok = !(r2.cratesIo.m ? embassy-foo-prev);
    }
    {
      name = "a crate gone from the tree stops evaluation";
      ok =
        fails
          (v.resolve {
            git.m.embassy-gone = { };
            cratesIo = { };
          }).git;
    }
    {
      name = "a crate versions.json has never heard of stops evaluation";
      ok =
        fails
          (v.resolve {
            git = { };
            cratesIo.m.embassy-new = { };
          }).cratesIo;
    }
    {
      name = "Cargo.toml: only requirements the new versions break are rewritten";
      ok =
        v.rewrite {
          text = cargo;
          versions = {
            embassy-foo = "0.4.0";
            embassy-bar = "1.3.0";
          };
        } == builtins.replaceStrings [ ''version = "0.3"'' ] [ ''version = "0.4.0"'' ] cargo;
    }
    {
      name = "Nix: block and inline forms, and an exact rust version";
      ok =
        v.rewrite {
          text = nix;
          versions = {
            embassy-foo = "0.4.2";
            embassy-bar = "1.3.0";
          };
          exact.rust = "1.2.3";
        } == builtins.replaceStrings [ ''"1.0.0"'' ''"0.9"'' ] [ ''"1.2.3"'' ''"1.3.0"'' ] nix;
    }
  ];

  failed = lib.filter (a: !a.ok) assertions;
in
if failed != [ ] then
  throw ''
    offline-devshells: embassy version derivation failed ${toString (lib.length failed)} assertion(s):
    ${lib.concatMapStringsSep "\n" (a: "  - ${a.name}") failed}
  ''
else
  pkgs.runCommandLocal "offline-devshells-embassy-versions" { } "touch $out"
