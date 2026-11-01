# SPDX-License-Identifier: MIT
#
# Reads a uv project's two lockfiles: uv.lock, which uv writes, and
# uv-purifier.lock.json, which `uv-purifier lock` writes beside it.
{
  # The project root, which holds uv.lock and pyproject.toml.
  src,
  lockFile ? src + "/uv-purifier.lock.json",
  uvLockFile ? src + "/uv.lock",
}:
let
  inherit (builtins)
    attrNames
    baseNameOf
    concatStringsSep
    filter
    fromJSON
    fromTOML
    hashFile
    hashString
    head
    listToAttrs
    map
    match
    readFile
    replaceStrings
    sort
    split
    substring
    ;

  supportedVersion = import ./lock-version.nix;

  purifier = fromJSON (readFile lockFile);
  uvLock = fromTOML (readFile uvLockFile);

  packageKey = package: "${package.name}==${package.version or ""}";

  # The file name of a locked URL, as the lock tool writes it: the last
  # segment of the URL's path, with the percent-escapes of PyPI file names
  # decoded.
  fileName =
    url:
    replaceStrings
      [
        "%2B"
        "%2b"
        "%21"
        "%25"
      ]
      [
        "+"
        "+"
        "!"
        "%"
      ]
      (baseNameOf (head (split "[?#]" url)));

  # A store path name from a file name. Store path names allow
  # [A-Za-z0-9+._?=-], must not start with a dot, and are at most 211
  # characters; every other character becomes "_".
  storeName =
    name:
    let
      replaced = concatStringsSep "" (
        map (part: if builtins.isList part then "_" else part) (split "[^A-Za-z0-9+._?=-]" name)
      );
      undotted = head (match "\\.*(.*)" replaced);
    in
    substring 0 200 (if undotted == "" then "file" else undotted);

  sourceOf = package: package.source or { };

  memberKind =
    package:
    let
      source = sourceOf package;
    in
    if source ? editable then
      "editable"
    else if source ? directory then
      "directory"
    else if source ? virtual then
      "virtual"
    else
      null;

  packages = uvLock.package or [ ];

  members = map (package: {
    inherit (package) name;
    key = packageKey package;
    kind = memberKind package;
    path = (sourceOf package).${memberKind package};
    dependencies = map (d: d.name) (package.dependencies or [ ]);
  }) (filter (package: memberKind package != null) packages);

  # The packages that come from an index or a URL, with the file names of
  # their wheels and sdist.
  distributions = map (
    package:
    let
      source = sourceOf package;
    in
    if source ? git then
      throw "uv-purifier: ${package.name} comes from git (${source.git}), which uv-purifier does not support yet"
    else if source ? path then
      throw "uv-purifier: ${package.name} comes from the local path ${source.path}, which uv-purifier does not support yet"
    else
      {
        inherit (package) name;
        key = packageKey package;
        wheels = map (wheel: fileName wheel.url) (package.wheels or [ ]);
        sdist = if package ? sdist then fileName package.sdist.url else null;
      }
  ) (filter (package: memberKind package == null) packages);

  # Every locked file by its file name, as a download entry of the shared
  # purifier library: its path in the wheelhouse, its URL and its SRI hash.
  uvFiles = builtins.concatMap (
    package:
    map (entry: {
      name = fileName entry.url;
      value = {
        path = fileName entry.url;
        inherit (entry) url;
        hash = builtins.convertHash {
          hash = replaceStrings [ "sha256:" ] [ "" ] entry.hash;
          hashAlgo = "sha256";
          toHashFormat = "sri";
        };
      };
    }) (package.wheels or [ ] ++ (if package ? sdist then [ package.sdist ] else [ ]))
  ) (filter (package: memberKind package == null) packages);

  purifierFiles = map (artifact: {
    name = artifact.path;
    value = artifact;
  }) purifier.artifacts;

  files = listToAttrs (uvFiles ++ purifierFiles);

  # The hash the lock tool records over uv.lock and the members'
  # pyproject.toml files (src/uv_purifier.py, inputs_hash).
  memberFiles = sort (a: b: a < b) (
    map (m: if m.path == "." then "pyproject.toml" else "${m.path}/pyproject.toml") members
  );
  inputsHash = hashString "sha256" (
    "uv.lock ${hashFile "sha256" uvLockFile}\n"
    + concatStringsSep "" (map (f: "${f} ${hashFile "sha256" (src + "/${f}")}\n") memberFiles)
  );
in
assert
  purifier.version == supportedVersion
  || throw "uv-purifier: ${toString lockFile} has lock format version ${toString purifier.version}; this library reads version ${toString supportedVersion}. Run `uv-purifier lock` with the version that provides this library.";
assert
  purifier.inputsHash == inputsHash
  || throw "uv-purifier: ${toString lockFile} does not match uv.lock and the pyproject.toml files of the workspace members. Run `uv-purifier lock`.";
{
  inherit
    purifier
    uvLock
    members
    distributions
    files
    fileName
    storeName
    ;
  inherit (purifier) builds buildRequirements;
  memberNames = map (m: m.name) members;
  # Every name in `files`, for tests.
  fileNames = attrNames files;
}
