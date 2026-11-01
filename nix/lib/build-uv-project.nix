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
  runCommand,
  writeText,
  fetchgit,
  unzip,
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
  # The local packages that uv.lock names by a path outside `src`, such as
  # "../shared", each mapped to a Nix path that holds it. A path inside
  # `src` is read from `src`.
  pathSources ? { },
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
  # A package from git, a URL or a local path is built from its source,
  # unless it is a wheel.
  builtDirect = filter (d: d.wheel == null) lock.direct;
  builds = buildClosure (
    map (m: m.key) builtMembers ++ map (d: d.key) builtDirect ++ concatMap (n: n.builds) dependencyNeeds
  );

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
          inherit (file) url mirrors hash;
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
  # `uv build --out-dir` also writes a .gitignore into the directory, which
  # is no distribution.
  uvBuild = args: ''
    uv build ${args} --out-dir $out
    rm -f $out/.gitignore
  '';

  membersByName = listToAttrs (
    map (m: {
      inherit (m) name;
      value = m;
    }) lock.members
  );

  memberVersion = m: lib.removePrefix "${m.name}==" m.key;

  # A local path of uv.lock, as a Nix path.
  localPath =
    path:
    if lock.insideProject path then
      src + "/${path}"
    else
      pathSources.${path}
        or (throw "uv-purifier: uv.lock names the local path ${path}, which is outside `src`. Pass it in `pathSources`, as `pathSources.\"${path}\" = <a Nix path>;`.");

  # The source a direct package builds from: a source tree, or an archive
  # that the build unpacks.
  directSource =
    d:
    if d.kind == "git" then
      let
        checkout = fetchgit {
          inherit (d.git.git) url rev;
          inherit (d.git) hash;
          fetchSubmodules = d.git.git.submodules;
        };
      in
      if d.subdirectory == null then checkout else "${checkout}/${d.subdirectory}"
    else if d.kind == "url" then
      fetch {
        name = lock.storeName (lock.fileName d.value);
        url = d.value;
        hash = d.sdistHash;
      }
    else
      localPath d.value;

  # A wheel of each direct package, in a directory of its own.
  directWheels = listToAttrs (
    map (d: {
      inherit (d) name;
      value =
        if d.wheel != null then
          linkFarm "${d.name}-wheel" [
            {
              inherit (d.wheel) name;
              path =
                if d.wheel.url != null then
                  fetch {
                    name = lock.storeName d.wheel.name;
                    inherit (d.wheel) url hash;
                  }
                else
                  localPath d.value;
            }
          ]
        else
          stdenvNoCC.mkDerivation {
            pname = "${d.name}-wheel";
            inherit (d) version;
            src = directSource d;
            nativeBuildInputs = [
              uv
              unzip
            ];
            # A project that reads its version from git, through
            # setuptools-scm or hatch-vcs, finds no repository in the
            # checkout and takes the version uv.lock records.
            env = uvEnv // {
              SETUPTOOLS_SCM_PRETEND_VERSION = d.version;
            };
            dontConfigure = true;
            buildPhase = ''
              runHook preBuild
              ${uvSetup}
              ${uvBuild "--wheel ."}
              runHook postBuild
            '';
            dontInstall = true;
            dontFixup = true;
          };
    }) lock.direct
  );

  # What split_requirements.py needs to swap the direct packages of an
  # exported requirements file for their wheels: each package from git or a
  # URL by its name, and each local package by its path.
  directIndex = writeText "uv-purifier-direct.json" (
    builtins.toJSON {
      names = listToAttrs (
        map (d: {
          inherit (d) name;
          value = "${directWheels.${d.name}}";
        }) (filter (d: d.kind == "git" || d.kind == "url") lock.direct)
      );
      paths = listToAttrs (
        map (d: {
          name = if lib.hasPrefix "/" d.value || lib.hasPrefix "." d.value then d.value else "./${d.value}";
          value = "${directWheels.${d.name}}";
        }) (filter (d: d.kind != "git" && d.kind != "url") lock.direct)
      );
    }
  );

  # What a member's build produces, as `uv-purifier lock` recorded it: the
  # file names of its sdist and wheel, and the scripts the wheel installs.
  outputsOf =
    m:
    (lock.purifier.outputs or { }).${m.name}
      or (throw "uv-purifier: uv-purifier.lock.json records no outputs of ${m.name}. Run `uv-purifier lock`.");

  # The file name of a member's wheel for this system and Python. The lock
  # run built the wheel on its own system, so a compiled wheel's CPython
  # tags and Linux platform tag are rewritten for this one; a pure wheel
  # keeps its name.
  wheelName =
    lockedName:
    let
      parts = lib.splitString "-" (lib.removeSuffix ".whl" lockedName);
      count = builtins.length parts;
      head = lib.take (count - 3) parts;
      pythonTag = builtins.elemAt parts (count - 3);
      abiTag = builtins.elemAt parts (count - 2);
      platformTag = builtins.elemAt parts (count - 1);
      cpython = "cp${lib.replaceStrings [ "." ] [ "" ] python.pythonVersion}";
      retag = tag: if builtins.match "cp3[0-9]+" tag != null then cpython else tag;
      platform =
        if platformTag == "any" then
          "any"
        else if builtins.match "linux_.*" platformTag != null then
          "linux_${stdenvNoCC.hostPlatform.parsed.cpu.name}"
        else
          throw "uv-purifier: the lock run built ${lockedName}, whose platform tag ${platformTag} is not one a uv build makes on Linux";
    in
    lib.concatStringsSep "-" (
      head
      ++ [
        (if abiTag == "abi3" then pythonTag else retag pythonTag)
        (retag abiTag)
        platform
      ]
    )
    + ".whl";

  packages = listToAttrs (
    map (m: {
      inherit (m) name;
      value = stdenvNoCC.mkDerivation (
        finalAttrs:
        let
          outputs = outputsOf m;
          files = [
            outputs.sdist
            (wheelName outputs.wheel)
          ];
        in
        {
          pname = m.name;
          version = memberVersion m;
          inherit src;
          nativeBuildInputs = [ uv ];
          env = uvEnv;
          dontConfigure = true;
          buildPhase = ''
            runHook preBuild
            ${uvSetup}
            ${uvBuild "--package ${lib.escapeShellArg m.name}"}
            for file in ${lib.escapeShellArgs files}; do
              if [ ! -f "$out/$file" ]; then
                echo "uv-purifier: the build of ${m.name} made $(ls $out), not $file as uv-purifier.lock.json records. Run \`uv-purifier lock\`." >&2
                exit 1
              fi
            done
            runHook postBuild
          '';
          dontInstall = true;
          dontFixup = true;
          # Each file the build makes, by its name, known when Nix
          # evaluates.
          passthru.artifacts = lib.genAttrs files (file: "${finalAttrs.finalPackage}/${file}");
        }
      );
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
      value = stdenvNoCC.mkDerivation (finalAttrs: {
        pname = "${m.name}-environment";
        version = memberVersion m;
        inherit src;
        nativeBuildInputs = [ uv ];
        env = uvEnv;
        dontConfigure = true;
        # The scripts of the member and of the members it depends on, by
        # name, known when Nix evaluates.
        passthru.scripts = lib.genAttrs (lib.concatMap (name: (outputsOf membersByName.${name}).scripts) (
          filter (name: packages ? ${name}) (memberClosure m.name)
        )) (script: "${finalAttrs.finalPackage}/bin/${script}");
        postBuild = ''
          for script in ${lib.escapeShellArgs (builtins.attrNames finalAttrs.passthru.scripts)}; do
            if [ ! -x "$out/bin/$script" ]; then
              echo "uv-purifier: the environment of ${m.name} has no script $script, which uv-purifier.lock.json records. Run \`uv-purifier lock\`." >&2
              exit 1
            fi
          done
        '';
        buildPhase = ''
          runHook preBuild
          ${uvSetup}
          uv export --frozen --no-dev --package ${lib.escapeShellArg m.name} --no-emit-workspace \
            --format requirements.txt --output-file "$TMPDIR/exported.txt"
          ${python.interpreter} -I ${./split_requirements.py} "$TMPDIR/exported.txt" ${directIndex} \
            "$TMPDIR/requirements.txt" "$TMPDIR/direct-wheels.txt"
          uv venv "$out"
          uv pip install --python "$out/bin/python" --require-hashes -r "$TMPDIR/requirements.txt"
          while read -r wheels; do
            uv pip install --python "$out/bin/python" --no-deps "$wheels"/*.whl
          done < "$TMPDIR/direct-wheels.txt"
          ${lib.concatMapStrings (name: ''
            uv pip install --python "$out/bin/python" --no-deps ${packages.${name}}/*.whl
          '') (filter (name: packages ? ${name}) (memberClosure m.name))}
          runHook postBuild
        '';
        dontInstall = true;
      });
    }) lock.members
  );

  # What `uv-purifier sync` installs a development environment from: the
  # Python of the build, the wheelhouse, and the wheels of the direct
  # packages with the index that split_requirements.py reads.
  interactive = runCommand "uv-purifier-interactive" { } ''
    mkdir $out
    ln -s ${python.interpreter} $out/python
    ln -s ${wheelhouse} $out/wheelhouse
    ln -s ${directIndex} $out/direct.json
    ln -s ${./split_requirements.py} $out/split_requirements.py
  '';
in
{
  inherit
    lock
    wheelhouse
    packages
    environments
    directWheels
    interactive
    ;
}
