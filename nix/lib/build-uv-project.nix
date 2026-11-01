# SPDX-License-Identifier: MIT
#
# `lib.uv-purifier.buildUvProject`: builds a uv project in the Nix sandbox
# from its two lockfiles, as the purifier contract
# (github:nix-purifiers/purifier, CONTRACT.md) describes.
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
# The result has:
# - `packages.<member>`: for each workspace member, a virtual environment
#   with the member and its runtime dependencies installed, and the
#   member's scripts in `bin/`, by name in `.scripts`.
# - `tests`: the project's test command, run in a development environment
#   (the default dependency groups and every member) on a copy of `src`.
# - `release`: the sdist and wheel of every member with a build, which
#   `uv-purifier publish` uploads, by file name in `.artifacts`.
# - `fetches`: the download entries of the shared library that the build
#   fetches for this system.
# - `interactive`: what `uv-purifier prefetch` installs the project's .venv
#   from.
{
  # The shared library of the nix-purifiers (github:nix-purifiers/purifier),
  # which fetches download entries and holds the wheel helpers.
  purifier,
}:
{
  pkgs,
  # The project root, which holds uv.lock, uv-purifier.lock.json and the
  # root pyproject.toml.
  src,
  # The fetchers of the shared library's fetchEntry and tree, such as a
  # `fetchurl` that sends credentials or uses a company mirror.
  fetchers ? { },
  # The Python the project builds and runs with. It must satisfy the
  # project's requires-python.
  python ? pkgs.python3,
  # The purifier lockfile. A file outside `src` replaces any copy in it,
  # so a packaging flake can build a project its author does not change.
  lockFile ? src + "/uv-purifier.lock.json",
  # uv's lockfile, for a `src` that has none, or to replace the one it has.
  uvLock ? src + "/uv.lock",
  # The local packages that uv.lock names by a path outside `src`, such as
  # "../shared", each mapped to a Nix path that holds it. A path inside
  # `src` is read from `src`.
  pathSources ? { },
  # The command `tests` runs in the development environment, from a copy of
  # `src`.
  testCommand ? [ "pytest" ],
}:
let
  inherit (pkgs)
    lib
    stdenvNoCC
    linkFarm
    runCommand
    writeText
    unzip
    uv
    glibc
    ;
  inherit (builtins)
    concatMap
    elemAt
    filter
    genericClosure
    listToAttrs
    map
    ;

  lock = import ./lock.nix {
    inherit src lockFile;
    uvLockFile = uvLock;
  };

  # The source the builds run in: `src` itself, or a copy of it with the
  # lockfiles given outside it, since uv reads uv.lock from the project.
  buildSrc =
    if lockFile == src + "/uv-purifier.lock.json" && uvLock == src + "/uv.lock" then
      src
    else
      runCommand "${baseNameOf (toString src)}-locked" { } ''
        cp -r ${src} $out
        chmod -R u+w $out
        cp ${uvLock} $out/uv.lock
        cp ${lockFile} $out/uv-purifier.lock.json
      '';

  # The library's fetchers get the package set, so that a file entry's
  # mirrors are tried.
  fetchArgs = {
    inherit pkgs;
  }
  // fetchers;
  fetch = purifier.fetchEntry fetchArgs;

  platform = stdenvNoCC.hostPlatform;
  target = "Python ${python.pythonVersion} on ${platform.system}";
  wheelTarget = {
    inherit (python) pythonVersion;
    arch = platform.parsed.cpu.name;
    glibcVersion = glibc.version;
  };
  installs = purifier.wheels wheelTarget;

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

  # Every chosen file, as a file entry at its file name.
  wheelhouseEntries = map (
    name:
    lock.files.${name}
      or (throw "uv-purifier: neither lockfile has the URL of ${name}. Run `uv-purifier lock`.")
  ) fileNames;

  wheelhouse = purifier.tree (
    fetchArgs
    // {
      name = "uv-purifier-wheelhouse";
      entries = wheelhouseEntries;
    }
  );

  # A file entry of the shared library for a URL and hash of uv.lock.
  fileEntry = url: hash: {
    path = lock.fileName url;
    inherit url hash;
    mirrors = [ ];
  };

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

  # The download entries of a direct package: a git checkout, or the file
  # at a URL. A local package has none.
  directEntries =
    d:
    if d.kind == "git" then
      [ d.git ]
    else if d.kind == "url" then
      [
        (if d.wheel != null then fileEntry d.wheel.url d.wheel.hash else fileEntry d.value d.sdistHash)
      ]
    else
      [ ];

  # The source a direct package builds from: a source tree, or an archive
  # that the build unpacks.
  directSource =
    d:
    if d.kind == "git" then
      let
        checkout = fetch d.git;
      in
      if d.subdirectory == null then checkout else "${checkout}/${d.subdirectory}"
    else if d.kind == "url" then
      fetch (fileEntry d.value d.sdistHash)
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
                if d.wheel.url != null then fetch (fileEntry d.wheel.url d.wheel.hash) else localPath d.value;
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

  # What a member's build produces, derived from uv.lock and the member's
  # pyproject.toml (src/uv_purifier.py, derived_outputs): the sdist and a
  # pure wheel named after the normalized name and the version uv.lock
  # records, and the scripts of [project.scripts] and [project.gui-scripts].
  derivedOutputs =
    m:
    let
      version = memberVersion m;
      stem = lib.toLower (
        lib.concatStrings (
          map (part: if builtins.isList part then "_" else part) (builtins.split "[-_.]+" m.name)
        )
      );
      project =
        (builtins.fromTOML (builtins.readFile (src + "/${m.path}/pyproject.toml"))).project or { };
      dynamic = project.dynamic or [ ];
    in
    {
      sdist = if version == "" then null else "${stem}-${version}.tar.gz";
      wheel = if version == "" then null else "${stem}-${version}-py3-none-any.whl";
      scripts =
        if lib.elem "scripts" dynamic || lib.elem "gui-scripts" dynamic then
          null
        else
          lib.sort (a: b: a < b) (
            lib.unique (
              builtins.attrNames (project.scripts or { }) ++ builtins.attrNames (project.gui-scripts or { })
            )
          );
    };

  # What a member's build produces: what Nix derives, with what
  # `uv-purifier lock` recorded where the build makes something else.
  outputsOf =
    m:
    let
      outputs = derivedOutputs m // (lock.purifier.outputs or { }).${m.name} or { };
      unknown = lib.filter (field: outputs.${field} == null) (builtins.attrNames outputs);
    in
    if unknown != [ ] then
      throw "uv-purifier: uv-purifier.lock.json records no ${lib.concatStringsSep ", " unknown} of ${m.name}. Run `uv-purifier lock`."
    else
      outputs;

  # The file name of a member's wheel for this system and Python. The lock
  # run built the wheel on its own system, so a compiled wheel's tags are
  # rewritten for this one; a pure wheel keeps its name.
  wheelName = purifier.wheelName wheelTarget;

  distributionFiles =
    m:
    let
      outputs = outputsOf m;
    in
    [
      outputs.sdist
      (wheelName outputs.wheel)
    ];

  # What `uv build` makes for each member with a build: its sdist, and its
  # wheel built from the sdist.
  distributions = listToAttrs (
    map (m: {
      inherit (m) name;
      value = stdenvNoCC.mkDerivation {
        pname = "${m.name}-distributions";
        version = memberVersion m;
        src = buildSrc;
        nativeBuildInputs = [ uv ];
        env = uvEnv;
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          ${uvSetup}
          ${uvBuild "--package ${lib.escapeShellArg m.name}"}
          for file in ${lib.escapeShellArgs (distributionFiles m)}; do
            if [ ! -f "$out/$file" ]; then
              echo "uv-purifier: the build of ${m.name} made $(ls $out), not $file as uv-purifier.lock.json records. Run \`uv-purifier lock\`." >&2
              exit 1
            fi
          done
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

  # Installs into the virtual environment $out the requirements that
  # `uv export` writes with `exportArgs`, the direct packages among them
  # from their wheels, and the wheels of `members`.
  installEnvironment = exportArgs: members: ''
    ${uvSetup}
    uv export --frozen ${exportArgs} --no-emit-workspace \
      --format requirements.txt --output-file "$TMPDIR/exported.txt"
    ${python.interpreter} -I ${./split_requirements.py} "$TMPDIR/exported.txt" ${directIndex} \
      "$TMPDIR/requirements.txt" "$TMPDIR/direct-wheels.txt"
    uv venv "$out"
    uv pip install --python "$out/bin/python" --require-hashes -r "$TMPDIR/requirements.txt"
    while read -r wheels; do
      uv pip install --python "$out/bin/python" --no-deps "$wheels"/*.whl
    done < "$TMPDIR/direct-wheels.txt"
    ${lib.concatMapStrings (name: ''
      uv pip install --python "$out/bin/python" --no-deps ${distributions.${name}}/*.whl
    '') (filter (name: distributions ? ${name}) members)}
  '';

  packages = listToAttrs (
    map (m: {
      inherit (m) name;
      value = stdenvNoCC.mkDerivation (finalAttrs: {
        pname = m.name;
        version = memberVersion m;
        src = buildSrc;
        nativeBuildInputs = [ uv ];
        env = uvEnv;
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          ${installEnvironment "--no-dev --package ${lib.escapeShellArg m.name}" (memberClosure m.name)}
          runHook postBuild
        '';
        # The scripts of the member and of the members it depends on, by
        # name, known when Nix evaluates.
        passthru.scripts = lib.genAttrs (lib.concatMap (name: (outputsOf membersByName.${name}).scripts) (
          filter (name: distributions ? ${name}) (memberClosure m.name)
        )) (script: "${finalAttrs.finalPackage}/bin/${script}");
        postBuild = ''
          for script in ${lib.escapeShellArgs (builtins.attrNames finalAttrs.passthru.scripts)}; do
            if [ ! -x "$out/bin/$script" ]; then
              echo "uv-purifier: the environment of ${m.name} has no script $script, which uv-purifier.lock.json records. Run \`uv-purifier lock\`." >&2
              exit 1
            fi
          done
        '';
        dontInstall = true;
      });
    }) lock.members
  );

  projectName =
    let
      roots = filter (m: m.path == ".") lock.members;
    in
    if roots != [ ] then (lib.head roots).name else "uv-project";

  # Every member with the default dependency groups, as `uv sync` installs
  # a project for development.
  development = stdenvNoCC.mkDerivation {
    pname = "${projectName}-development";
    version = "0";
    src = buildSrc;
    nativeBuildInputs = [ uv ];
    env = uvEnv;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      ${installEnvironment "--all-packages" (map (m: m.name) builtMembers)}
      runHook postBuild
    '';
    dontInstall = true;
  };

  tests = runCommand "${projectName}-tests" { } ''
    cp -r ${buildSrc} project
    chmod -R u+w project
    cd project
    export HOME=$TMPDIR PATH=${development}/bin:$PATH VIRTUAL_ENV=${development} PYTHONDONTWRITEBYTECODE=1
    ${lib.escapeShellArgs testCommand}
    touch $out
  '';

  release =
    runCommand "${projectName}-release"
      {
        passthru = {
          # Each file `publish` uploads, by its name, known when Nix evaluates.
          artifacts = lib.listToAttrs (
            lib.concatMap (
              m:
              map (file: {
                name = file;
                value = "${distributions.${m.name}}/${file}";
              }) (distributionFiles m)
            ) builtMembers
          );
          # The release of each member, which `publish --package` uploads.
          members = distributions;
        };
      }
      ''
        mkdir $out
        ${lib.concatMapStrings (name: ''
          ln -s ${distributions.${name}}/* $out/
        '') (builtins.attrNames distributions)}
      '';

  fetches = wheelhouseEntries ++ concatMap directEntries lock.direct;

  # What `uv-purifier prefetch` installs the project's .venv from: the
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
    packages
    tests
    release
    fetches
    interactive
    lock
    ;
}
