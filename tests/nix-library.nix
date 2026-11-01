# SPDX-License-Identifier: MIT
#
# Unit tests of the Nix library that need no build: wheel selection, and the
# check that uv-purifier.lock.json still matches uv.lock.
{ pkgs }:
let
  inherit (pkgs) lib;

  installs = import ../nix/lib/wheels.nix {
    pythonVersion = "3.14";
    arch = "x86_64";
    glibcVersion = "2.40";
  };

  wheelCases = {
    pure = installs "attrs-25.3.0-py3-none-any.whl";
    pythonTwoAndThree = installs "six-1.17.0-py2.py3-none-any.whl";
    sameCpython = installs "pydantic_core-2.41.4-cp314-cp314-manylinux_2_17_x86_64.manylinux2014_x86_64.whl";
    otherCpython = installs "pydantic_core-2.41.4-cp313-cp313-manylinux_2_17_x86_64.manylinux2014_x86_64.whl";
    stableAbi = installs "cryptography-46.0.3-cp311-abi3-manylinux_2_34_x86_64.whl";
    stableAbiNewerThanPython = installs "cryptography-46.0.3-cp315-abi3-manylinux_2_34_x86_64.whl";
    newerGlibc = installs "numpy-2.3.4-cp314-cp314-manylinux_2_41_x86_64.whl";
    otherArch = installs "numpy-2.3.4-cp314-cp314-manylinux_2_28_aarch64.whl";
    musl = installs "numpy-2.3.4-cp314-cp314-musllinux_1_2_x86_64.whl";
    macos = installs "numpy-2.3.4-cp314-cp314-macosx_14_0_arm64.whl";
    buildTag = installs "example-1.0-1-py3-none-any.whl";
    pythonTwoOnly = installs "example-1.0-py2-none-any.whl";
  };

  wheelExpected = {
    pure = true;
    pythonTwoAndThree = true;
    sameCpython = true;
    otherCpython = false;
    stableAbi = true;
    stableAbiNewerThanPython = false;
    newerGlibc = false;
    otherArch = false;
    musl = false;
    macos = false;
    buildTag = true;
    pythonTwoOnly = false;
  };

  # A uv.lock that differs from the one uv-purifier.lock.json was made
  # for: the lockfile must be refused.
  changedUvLock = builtins.toFile "uv.lock" (
    builtins.readFile ./fixtures/simple/uv.lock + "\n# changed\n"
  );
  staleLock =
    builtins.tryEval
      (import ../nix/lib/lock.nix {
        src = ./fixtures/simple;
        uvLockFile = changedUvLock;
      }).purifier;
  currentLock =
    builtins.tryEval
      (import ../nix/lib/lock.nix { src = ./fixtures/simple; }).purifier.version;

  failures =
    lib.filter (name: wheelCases.${name} != wheelExpected.${name}) (lib.attrNames wheelCases)
    ++ lib.optional staleLock.success "a stale uv-purifier.lock.json was accepted"
    ++ lib.optional (!currentLock.success) "the current uv-purifier.lock.json was refused";
in
pkgs.runCommand "uv-purifier-test-nix-library" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      echo "failed: "${lib.escapeShellArg (lib.concatStringsSep ", " failures)} >&2
      exit 1
    ''
)
