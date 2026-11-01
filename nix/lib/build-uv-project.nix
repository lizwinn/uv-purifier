# SPDX-License-Identifier: MIT
#
# Builds a uv project in the Nix sandbox from its two lockfiles.
#
# uv.lock pins the project's dependencies, and uv-purifier.lock.json pins
# the build requirements of the workspace members and of the dependencies
# that may have to be built from their sdists. For the system and Python it
# builds with, this function picks the locked files that the build needs:
# for each dependency, its wheels that install, or else its sdist and the
# build requirements that building it needs. It links them into one
# directory, the wheelhouse, and runs uv with no network and no index, so
# that uv reads nothing but the wheelhouse.
#
# The result has, for each workspace member:
# - `packages.<member>`: what `uv build` makes for the member, its sdist and
#   its wheel, which is what `uv publish` uploads. A virtual member, which
#   has no build, has no package.
# - `environments.<member>`: a virtual environment with the member and its
#   runtime dependencies installed, with the member's scripts in `bin/`.
{
  lib,
  stdenvNoCC,
  linkFarm,
  uv,
  python3,
  glibc,
}:
{
  # The project root, which holds uv.lock, uv-purifier.lock.json and the
  # root pyproject.toml.
  src,
  # The Python the project builds and runs with. It must satisfy the
  # project's requires-python.
  python ? python3,
  lockFile ? src + "/uv-purifier.lock.json",
  # A replacement for the fetcher of locked files; see nix/lib/fetch.nix.
  fetchurl ? null,
}:
let
  inherit (builtins)
    concatMap
    elemAt
    filter
    genericClosure
    listToAttrs
    map
    ;

  lock = import ./lock.nix { inherit src lockFile; };
  fetch = import ./fetch.nix { inherit fetchurl; };

  platform = stdenvNoCC.hostPlatform;
  target = "Python ${python.pythonVersion} on ${platform.system}";
  installs = import ./wheels.nix {
    inherit (python) pythonVersion;
    arch = platform.parsed.cpu.name;
    glibcVersion = glibc.version;
  };

  # What installing a locked distribution needs on this system: its wheels
  # that install, or else its sdist and a build of it.
  needs =
    distribution:
    let
      wheels = filter installs distribution.wheels;
    in
    if wheels != [ ] then
      {
        files = wheels;
        builds = [ ];
      }
    else if distribution.sdist != null then
      {
        files = [ distribution.sdist ];
        builds = [ distribution.key ];
      }
    else
      throw "uv-purifier: no wheel of ${distribution.key} installs with ${target}, and it has no sdist";

  # A package of a set of build requirements, in the shape of `needs`.
  requirementDistribution = package: {
    key = "${package.name}==${package.version}";
    inherit (package) wheels;
    sdist = package.sdist or null;
  };

  requirementSet =
    key:
    let
      set = elemAt lock.buildRequirements (
        lock.builds.${key}
          or (throw "uv-purifier: uv-purifier.lock.json has no build requirements for ${key}, which ${target} has to build. Run `uv-purifier lock`.")
      );
    in
    if set ? error then
      throw "uv-purifier: building ${key} with ${target} needs the build requirements ${lib.concatStringsSep ", " set.requires}, which `uv-purifier lock` could not resolve:\n${set.error}"
    else
      set;

  requirementNeeds = key: map (p: needs (requirementDistribution p)) (requirementSet key).packages;

  # The builds that some builds need, with the builds that their build
  # requirements need in turn.
  buildClosure =
    keys:
    map (item: item.key) (genericClosure {
      startSet = map (key: { inherit key; }) keys;
      operator = item: map (key: { inherit key; }) (concatMap (n: n.builds) (requirementNeeds item.key));
    });

  dependencyNeeds = map needs lock.distributions;
  builtMembers = filter (m: m.kind != "virtual") lock.members;
  builds = buildClosure (map (m: m.key) builtMembers ++ concatMap (n: n.builds) dependencyNeeds);

  fileNames = lib.unique (
    concatMap (n: n.files) dependencyNeeds
    ++ concatMap (key: concatMap (n: n.files) (requirementNeeds key)) builds
  );

  wheelhouse = linkFarm "uv-purifier-wheelhouse" (
    map (
      name:
      let
        file =
          lock.files.${name}
            or (throw "uv-purifier: neither lockfile has the URL of ${name}. Run `uv-purifier lock`.");
      in
      {
        inherit name;
        path = fetch {
          name = lock.storeName name;
          inherit (file) url hash;
        };
      }
    ) fileNames
  );

  # uv reads the wheelhouse and nothing else, with the Python of the build.
  uvEnv = {
    UV_OFFLINE = "1";
    UV_NO_INDEX = "1";
    UV_FIND_LINKS = "${wheelhouse}";
    UV_PYTHON = python.interpreter;
    UV_PYTHON_DOWNLOADS = "never";
    UV_LINK_MODE = "copy";
    UV_NO_PROGRESS = "1";
  };
  uvSetup = ''
    export HOME=$TMPDIR UV_CACHE_DIR=$TMPDIR/uv-cache
  '';

  membersByName = listToAttrs (
    map (m: {
      inherit (m) name;
      value = m;
    }) lock.members
  );

  memberVersion = m: lib.removePrefix "${m.name}==" m.key;

  packages = listToAttrs (
    map (m: {
      inherit (m) name;
      value = stdenvNoCC.mkDerivation {
        pname = m.name;
        version = memberVersion m;
        inherit src;
        nativeBuildInputs = [ uv ];
        env = uvEnv;
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          ${uvSetup}
          uv build --package ${lib.escapeShellArg m.name} --out-dir $out
          runHook postBuild
        '';
        dontInstall = true;
        dontFixup = true;
      };
    }) builtMembers
  );

  # A member with the members it depends on, transitively.
  memberClosure =
    name:
    map (item: item.key) (genericClosure {
      startSet = [ { key = name; } ];
      operator =
        item:
        map (key: { inherit key; }) (
          filter (d: membersByName ? ${d}) membersByName.${item.key}.dependencies
        );
    });

  environments = listToAttrs (
    map (m: {
      inherit (m) name;
      value = stdenvNoCC.mkDerivation {
        pname = "${m.name}-environment";
        version = memberVersion m;
        inherit src;
        nativeBuildInputs = [ uv ];
        env = uvEnv;
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          ${uvSetup}
          uv export --frozen --no-dev --package ${lib.escapeShellArg m.name} --no-emit-workspace \
            --format requirements.txt --output-file "$TMPDIR/requirements.txt"
          uv venv "$out"
          uv pip install --python "$out/bin/python" --require-hashes -r "$TMPDIR/requirements.txt"
          ${lib.concatMapStrings (name: ''
            uv pip install --python "$out/bin/python" --no-deps ${packages.${name}}/*.whl
          '') (filter (name: packages ? ${name}) (memberClosure m.name))}
          runHook postBuild
        '';
        dontInstall = true;
      };
    }) lock.members
  );
in
{
  inherit
    lock
    wheelhouse
    packages
    environments
    ;
}
