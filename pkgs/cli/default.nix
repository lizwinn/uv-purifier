# SPDX-License-Identifier: MIT
#
# The `uv-purifier` command. It runs with the uv of this package set, which
# is also the uv that buildUvProject runs, so `uv-purifier lock` checks
# uv.lock with the uv that will build from it. `publish` builds with the
# Nix library and the nixpkgs of this package set.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  uv,
  path,
}:
stdenvNoCC.mkDerivation {
  pname = "uv-purifier";
  version = lib.removeSuffix "\n" (builtins.readFile ../../version.txt);

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../src
      ../../nix/lib
    ];
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/uv-purifier
    cp src/uv_purifier.py $out/share/uv-purifier/
    cp -r nix/lib $out/share/uv-purifier/nix-lib
    makeWrapper ${python3.interpreter} $out/bin/uv-purifier \
      --add-flags "-I $out/share/uv-purifier/uv_purifier.py" \
      --prefix PATH : ${lib.makeBinPath [ uv ]} \
      --set UV_PURIFIER_NIX_LIB $out/share/uv-purifier/nix-lib \
      --set UV_PURIFIER_NIXPKGS ${path}
    runHook postInstall
  '';

  meta = {
    description = "Lock and publish uv projects that Nix builds";
    license = lib.licenses.mit;
    mainProgram = "uv-purifier";
  };
}
