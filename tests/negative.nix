# SPDX-License-Identifier: MIT
#
# The mistakes a developer makes with the lockfiles, each of which must
# fail with an error that says what went wrong and which command fixes it.
# Each case copies tests/fixtures/simple, breaks it, and evaluates the Nix
# library on it with nix-instantiate, which shows the error text that a
# `nix build` shows. builtins.tryEval cannot test this: it does not catch
# every error, and it hides the message.
{ pkgs }:
let
  inherit (pkgs) lib;

  # Each case: a shell command run in the copy, and a text the error must
  # contain. The case `unchanged` checks that the unbroken fixture
  # evaluates.
  cases = {
    unchanged = {
      break = "true";
      expect = null;
    };
    stale-uv-lock = {
      break = "echo '# changed' >> uv.lock";
      expect = "was made for another uv.lock";
    };
    dependency-added-without-uv-lock = {
      break = "sed -i 's/\"docopt==0.6.2\"/\"docopt==0.6.2\", \"six\"/' pyproject.toml";
      expect = "If pyproject.toml changed, run `uv lock`; then run `uv-purifier lock`";
    };
    tampered-hash = {
      break = edit "lock['artifacts'][0]['hash'] = 'sha256-' + 'A' * 43 + '='";
      expect = "was changed after `uv-purifier lock` wrote it";
    };
    missing-entry = {
      break = edit "del lock['builds'][sorted(lock['builds'])[0]]";
      expect = "was changed after `uv-purifier lock` wrote it";
    };
    malformed = {
      break = "head -c 200 uv-purifier.lock.json > broken && mv broken uv-purifier.lock.json";
      expect = "which is not valid JSON";
    };
    missing-lockfile = {
      break = "rm uv-purifier.lock.json";
      expect = "does not exist. Run `uv-purifier lock`";
    };
    other-format-version = {
      break = edit "lock['version'] = 0";
      expect = "has lock format version 0";
    };
  };

  # A Python edit of the parsed lockfile, written back.
  edit =
    statement:
    "${pkgs.python3.interpreter} -c ${lib.escapeShellArg ''
      import json
      lock = json.load(open("uv-purifier.lock.json"))
      ${statement}
      json.dump(lock, open("uv-purifier.lock.json", "w"), indent=2)
    ''}";

  runCase = name: case: ''
    echo "case ${name}"
    cp -r ${./fixtures/simple} ${name}
    chmod -R u+w ${name}
    (cd ${name} && ${case.break})
    if nix-instantiate --eval --strict --expr \
        "(import ${../nix/lib}/lock.nix { src = $PWD/${name}; }).purifier.version" \
        > ${name}.out 2> ${name}.err; then
      ${
        if case.expect == null then
          "true"
        else
          ''
            echo "case ${name} evaluated, but it should fail with: "${lib.escapeShellArg case.expect} >&2
            exit 1
          ''
      }
    else
      ${
        if case.expect == null then
          ''
            cat ${name}.err >&2
            echo "case ${name} failed, but it should evaluate" >&2
            exit 1
          ''
        else
          ''
            if ! grep -qF ${lib.escapeShellArg case.expect} ${name}.err; then
              cat ${name}.err >&2
              echo "case ${name} failed without: "${lib.escapeShellArg case.expect} >&2
              exit 1
            fi
          ''
      }
    fi
  '';
in
pkgs.runCommand "uv-purifier-test-negative" { nativeBuildInputs = [ pkgs.nix ]; } ''
  # A Nix of its own, with its state in the build directory.
  export NIX_STATE_DIR=$TMPDIR/nix/state NIX_STORE_DIR=$TMPDIR/nix/store \
    NIX_LOCALSTATE_DIR=$TMPDIR/nix/var NIX_LOG_DIR=$TMPDIR/nix/log \
    NIX_CONF_DIR=$TMPDIR/nix/etc HOME=$TMPDIR
  mkdir -p $NIX_CONF_DIR
  ${lib.concatStrings (lib.mapAttrsToList runCase cases)}
  touch $out
''
