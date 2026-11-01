# SPDX-License-Identifier: MIT
"""uv-purifier: locks what a uv project needs beyond uv.lock, so that Nix can
build the project offline in its sandbox.

uv.lock pins every runtime and development dependency with its URL and hash,
and the Nix library reads it directly. It leaves out the build requirements:
the packages that a workspace member's build backend needs, and the packages
that building a dependency from its sdist needs. `uv-purifier lock` resolves
those with uv itself and writes them to uv-purifier.lock.json beside uv.lock.
"""

import argparse
import base64
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.parse
import urllib.request
import zipfile

LOCK_FILE = "uv-purifier.lock.json"
FORMAT_VERSION = 1

# The build requirements PEP 517 prescribes, and uv uses, for a project
# without a [build-system] table or without its `requires` key.
DEFAULT_BUILD_REQUIRES = ["setuptools>=40.8.0"]

# The keys of [tool.uv] that choose where packages come from. The throwaway
# projects that resolve build requirements copy them from the root
# pyproject.toml, so build requirements resolve from the same indexes as the
# project's own dependencies.
INDEX_KEYS = (
    "index",
    "index-url",
    "extra-index-url",
    "find-links",
    "index-strategy",
    "no-index",
)


class Error(Exception):
    pass


def log(message):
    print(f"uv-purifier: {message}", file=sys.stderr)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sri(uv_hash):
    """Converts a uv.lock hash ("sha256:<hex>") to an SRI hash."""
    algorithm, _, hexdigest = uv_hash.partition(":")
    if algorithm != "sha256":
        raise Error(f"unsupported hash algorithm in {uv_hash}")
    return "sha256-" + base64.b64encode(bytes.fromhex(hexdigest)).decode()


def file_name(url):
    """The file name a distribution has in the flat directory the Nix build
    reads: the last segment of its URL, percent-decoded."""
    return urllib.parse.unquote(urllib.parse.urlparse(url).path.rsplit("/", 1)[-1])


def package_key(package):
    return f"{package['name']}=={package.get('version', '')}"


def is_pure_wheel(name):
    """Whether a wheel installs on every platform: its ABI tag is `none` and
    its platform tag is `any`."""
    stem = name[: -len(".whl")]
    parts = stem.split("-")
    return len(parts) >= 5 and parts[-2] == "none" and parts[-1] == "any"


def entry_name(entry):
    """The file name of a wheel or sdist entry of uv.lock. An entry of a
    registry package has a URL; an entry of a local file has a path or a
    file name."""
    for key in ("url", "path", "filename"):
        if key in entry:
            return file_name(entry[key])
    raise Error(f"uv.lock has a file entry without a URL, path or file name: {entry}")


def may_need_build(package):
    """Whether some platform may have to build this registry package from
    its sdist: it has an sdist and no wheel that installs everywhere. The Nix
    library decides per system and Python version which of these it
    actually builds, and fetches only their build requirements."""
    if "sdist" not in package:
        return False
    return not any(is_pure_wheel(entry_name(w)) for w in package.get("wheels", []))


# The kinds of `source` in uv.lock. `editable`, `directory` and `virtual`
# are source trees in the project; a workspace member is one of them.
SOURCE_KINDS = ("registry", "git", "url", "path", "directory", "editable", "virtual")


def source_kind(package):
    source = package.get("source", {})
    for kind in SOURCE_KINDS:
        if kind in source:
            return kind, source[kind]
    raise Error(f"{package['name']} has a source uv-purifier does not know: {source}")


def workspace_members(uv_lock):
    """The names of the workspace members. A workspace lists them in
    [manifest]; a single project is its own member, the source tree at the
    project root."""
    manifest = uv_lock.get("manifest", {})
    if "members" in manifest:
        return set(manifest["members"])
    return {
        p["name"]
        for p in uv_lock.get("package", [])
        if source_kind(p)[0] in ("editable", "directory", "virtual") and source_kind(p)[1] == "."
    }


def parse_git_source(value):
    """Splits a git source of uv.lock, such as
    `https://host/repo?tag=v1&subdirectory=pkg#<commit>`, into the
    repository URL, the commit and the subdirectory."""
    parsed = urllib.parse.urlparse(value)
    query = urllib.parse.parse_qs(parsed.query)
    if not parsed.fragment:
        raise Error(f"the git source {value} names no commit")
    repository = urllib.parse.urlunparse(parsed._replace(query="", fragment=""))
    return repository, parsed.fragment, query.get("subdirectory", [None])[0]


def prefetch_git(repository, commit):
    """Fetches a commit with its submodules, as uv checks it out, and returns
    the store path of the checkout and its NAR hash."""
    result = subprocess.run(
        [
            "nix-prefetch-git",
            "--url", repository,
            "--rev", commit,
            "--fetch-submodules",
            "--quiet",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise Error(f"nix-prefetch-git could not fetch {repository} at {commit}:\n{result.stderr.strip()}")
    info = json.loads(result.stdout)
    return info["path"], info["hash"]


def check_hash(path, expected_uv_hash, what):
    algorithm, _, expected = expected_uv_hash.partition(":")
    actual = sha256_file(path)
    if algorithm != "sha256" or actual != expected:
        raise Error(f"{what} has sha256 {actual}, but uv.lock says {expected_uv_hash}")


def build_requires(pyproject):
    build_system = pyproject.get("build-system")
    if build_system is None or "requires" not in build_system:
        return list(DEFAULT_BUILD_REQUIRES)
    return list(build_system["requires"])


# The backend PEP 517 prescribes, and uv uses, for a project without a
# `build-backend`.
DEFAULT_BUILD_BACKEND = "setuptools.build_meta:__legacy__"

# Asks a build backend for the requirements it adds at build time, through
# the PEP 517 hooks, as uv's build isolation does. It runs in the source tree
# with the static build requirements installed, and prints a JSON list.
HOOKS_SCRIPT = """
import importlib, json, sys
sys.path[:0] = json.loads(sys.argv[2])
module, _, attribute = sys.argv[1].partition(":")
backend = importlib.import_module(module)
for part in filter(None, attribute.split(".")):
    backend = getattr(backend, part)
requires = []
for hook in (
    "get_requires_for_build_sdist",
    "get_requires_for_build_wheel",
    "get_requires_for_build_editable",
):
    if hasattr(backend, hook):
        requires += getattr(backend, hook)({})
print(json.dumps(requires))
"""


def dynamic_requires(tree, pyproject, static, workdir):
    """The requirements the build backend of a source tree reports through
    its PEP 517 hooks for an sdist, a wheel and an editable install. A
    backend such as hatchling asks for `editables` only this way."""
    build_system = pyproject.get("build-system", {})
    backend = build_system.get("build-backend", DEFAULT_BUILD_BACKEND)
    backend_path = [os.path.join(tree, p) for p in build_system.get("backend-path", [])]
    venv = tempfile.mkdtemp(dir=workdir)
    for args in (["venv", "--quiet", venv], ["pip", "install", "--quiet", "--python", venv, *static]):
        result = run_uv(args, cwd=tree)
        if result.returncode != 0:
            raise Error(f"installing the build requirements {', '.join(static)} failed:\n{result.stderr.strip()}")
    result = subprocess.run(
        [os.path.join(venv, "bin", "python"), "-c", HOOKS_SCRIPT, backend, json.dumps(backend_path)],
        cwd=tree,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise Error(f"the build backend {backend} failed to report its requirements:\n{result.stderr.strip()}")
    return json.loads(result.stdout.strip().splitlines()[-1])


def unpack(archive, workdir):
    """Unpacks an sdist or source archive and returns its source tree: the
    single top directory, as in an sdist or a GitHub archive, or else the
    unpacked root."""
    target = tempfile.mkdtemp(dir=workdir)
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as z:
            z.extractall(target)
    else:
        with tarfile.open(archive) as t:
            t.extractall(target, filter="data")
    entries = os.listdir(target)
    if len(entries) == 1 and os.path.isdir(os.path.join(target, entries[0])):
        return os.path.join(target, entries[0])
    return target


def scratch_copy(tree, workdir):
    """A writable copy of a source tree. A backend may write into the tree
    while it reports its requirements, as setuptools writes its egg-info, so
    the hooks run on a copy rather than on the project or a store path."""
    copy = os.path.join(tempfile.mkdtemp(dir=workdir), "tree")
    shutil.copytree(tree, copy, ignore=shutil.ignore_patterns(".git", ".venv", "__pycache__", "dist"))
    subprocess.run(["chmod", "-R", "u+w", copy], check=True)
    return copy


def tree_requirements(tree, workdir):
    """Every build requirement of a source tree: the static ones of its
    [build-system] table and the ones its backend adds."""
    pyproject = tree_pyproject(tree)
    static = build_requires(pyproject)
    requires = list(static)
    for requirement in dynamic_requires(tree, pyproject, static, workdir):
        if requirement not in requires:
            requires.append(requirement)
    return requires


def download(url, expected_uv_hash, directory):
    """Downloads a locked file and checks its hash."""
    target = tempfile.mkdtemp(dir=directory)
    target = os.path.join(target, file_name(url) or "download")
    with urllib.request.urlopen(url) as response, open(target, "wb") as out:
        shutil.copyfileobj(response, out)
    check_hash(target, expected_uv_hash, url)
    return target


def tree_pyproject(directory):
    """The pyproject.toml of a source tree, or {} when it has none."""
    path = os.path.join(directory, "pyproject.toml")
    if not os.path.exists(path):
        return {}
    with open(path, "rb") as f:
        return tomllib.load(f)


def sdist_pyproject(path):
    """The pyproject.toml at the top of an sdist or source archive, or {}
    when it has none. The archive's top directory may have any name, as in a
    GitHub archive."""
    candidates = {}
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            for name in archive.namelist():
                parts = name.split("/")
                if len(parts) == 2 and parts[1] == "pyproject.toml":
                    candidates[name] = archive.read(name)
    else:
        with tarfile.open(path) as archive:
            for member in archive.getmembers():
                parts = member.name.split("/")
                if len(parts) == 2 and parts[1] == "pyproject.toml" and member.isfile():
                    extracted = archive.extractfile(member)
                    if extracted is not None:
                        candidates[member.name] = extracted.read()
    if not candidates:
        return {}
    return tomllib.load(io.BytesIO(candidates[min(candidates)]))


def run_uv(args, cwd, env=None):
    result = subprocess.run(
        ["uv", *args], cwd=cwd, env=env, text=True, capture_output=True, check=False
    )
    return result


def resolve_build_requirements(requires, requires_python, index_config, workdir):
    """Resolves one set of build requirements for every platform, by locking
    a throwaway project that depends on them. Returns uv.lock's packages."""
    project = tempfile.mkdtemp(dir=workdir)
    lines = [
        "[project]",
        'name = "uv-purifier-build-requirements"',
        'version = "0"',
        f"requires-python = {json.dumps(requires_python)}",
        f"dependencies = {json.dumps(requires)}",
        "",
        "[tool.uv]",
        "package = false",
    ]
    with open(os.path.join(project, "pyproject.toml"), "w") as f:
        f.write("\n".join(lines) + "\n")
        for key, value in index_config.items():
            f.write(toml_assignment(key, value))
    result = run_uv(["lock", "--quiet"], cwd=project)
    if result.returncode != 0:
        raise Error(result.stderr.strip())
    with open(os.path.join(project, "uv.lock"), "rb") as f:
        lock = tomllib.load(f)
    return [
        p
        for p in lock.get("package", [])
        if p["name"] != "uv-purifier-build-requirements"
    ]


def toml_assignment(key, value):
    """A [tool.uv] entry for the throwaway project, in TOML. Index entries
    are a list of tables; the other keys are strings, lists of strings or
    booleans, which JSON writes the way TOML reads them."""
    if key == "index":
        out = []
        for table in value:
            out.append("\n[[tool.uv.index]]\n")
            for k, v in table.items():
                out.append(f"{k} = {json.dumps(v)}\n")
        return "".join(out)
    return f"{key} = {json.dumps(value)}\n"


def inputs_hash(root, tree_dirs):
    """The hash the Nix library compares to tell whether the lockfile still
    matches uv.lock and the pyproject.toml files of the source trees in the
    project. nix/lib/lock.nix computes the same text. A source tree outside
    the project contributes no file, because the Nix build may take it from
    elsewhere."""
    files = ["uv.lock"] + sorted(
        "pyproject.toml" if d == "." else f"{d}/pyproject.toml"
        for d in tree_dirs
        if inside_project(d) and os.path.exists(os.path.join(root, d, "pyproject.toml"))
    )
    text = "".join(f"{f} {sha256_file(os.path.join(root, f))}\n" for f in files)
    return hashlib.sha256(text.encode()).hexdigest()


def inside_project(path):
    return not (path == ".." or path.startswith(("/", "../")))


def lock(root):
    uv_lock_path = os.path.join(root, "uv.lock")
    if not os.path.exists(uv_lock_path):
        raise Error(f"{root} has no uv.lock; run `uv lock` first")
    check = run_uv(["lock", "--check", "--quiet"], cwd=root)
    if check.returncode != 0:
        raise Error(
            "uv.lock does not match the project; run `uv lock` first\n" + check.stderr.strip()
        )
    with open(uv_lock_path, "rb") as f:
        uv_lock = tomllib.load(f)
    with open(os.path.join(root, "pyproject.toml"), "rb") as f:
        root_pyproject = tomllib.load(f)
    tool_uv = root_pyproject.get("tool", {}).get("uv", {})
    index_config = {k: tool_uv[k] for k in INDEX_KEYS if k in tool_uv}
    requires_python = uv_lock.get("requires-python", ">=3")

    artifacts = {}
    requirement_sets = []
    set_index = {}
    builds = {}
    sources = {}
    tree_dirs = []

    def add_artifact(entry):
        name = file_name(entry["url"])
        known = artifacts.get(name)
        record = {"path": name, "url": entry["url"], "hash": sri(entry["hash"])}
        if known is not None and known != record:
            raise Error(f"two locked files are both named {name}: {known['url']} and {entry['url']}")
        artifacts[name] = record
        return name

    pending = []

    def request(key, requires):
        canonical = tuple(sorted(requires))
        if canonical not in set_index:
            set_index[canonical] = len(requirement_sets)
            requirement_sets.append({"requires": list(canonical)})
            pending.append(canonical)
        builds[key] = set_index[canonical]

    def outside_or_local(path):
        return path if os.path.isabs(path) else os.path.normpath(os.path.join(root, path))

    def request_tree(key, tree, workdir):
        """Locks the build requirements of a source tree. When its backend
        cannot report the requirements it adds, the static ones stand, and
        a build that needs more fails in the sandbox with uv's error."""
        log(f"reading the build requirements of {key}")
        try:
            requires = tree_requirements(tree, workdir)
        except Error as e:
            log(f"using only the static build requirements of {key}: {e}")
            requires = build_requires(tree_pyproject(tree))
        request(key, requires)

    with tempfile.TemporaryDirectory(prefix="uv-purifier-") as workdir:
        for package in uv_lock.get("package", []):
            key = package_key(package)
            kind, value = source_kind(package)
            if kind in ("editable", "directory", "virtual"):
                tree_dirs.append(value)
                if kind == "virtual":
                    continue
                request_tree(key, scratch_copy(outside_or_local(value), workdir), workdir)
            elif kind == "registry":
                if may_need_build(package):
                    sdist = package["sdist"]
                    downloaded = download(sdist["url"], sdist["hash"], workdir)
                    request_tree(key, unpack(downloaded, workdir), workdir)
            elif kind == "git":
                repository, commit, subdirectory = parse_git_source(value)
                log(f"fetching {package['name']} from {repository} at {commit}")
                checkout, nar_hash = prefetch_git(repository, commit)
                path = f"git/{package['name']}-{commit}"
                artifacts[path] = {
                    "path": path,
                    "git": {"url": repository, "rev": commit, "submodules": True},
                    "hash": nar_hash,
                }
                sources[key] = path
                copy = scratch_copy(checkout, workdir)
                tree = os.path.join(copy, subdirectory) if subdirectory else copy
                request_tree(key, tree, workdir)
            elif kind == "url":
                if "sdist" in package:
                    downloaded = download(value, package["sdist"]["hash"], workdir)
                    request_tree(key, unpack(downloaded, workdir), workdir)
            elif kind == "path":
                if "sdist" in package:
                    archive = outside_or_local(value)
                    check_hash(archive, package["sdist"]["hash"], value)
                    request_tree(key, unpack(archive, workdir), workdir)

        seen = set()
        while pending:
            canonical = pending.pop(0)
            entry = requirement_sets[set_index[canonical]]
            log(f"resolving the build requirements {', '.join(canonical)}")
            try:
                packages = resolve_build_requirements(
                    list(canonical), requires_python, index_config, workdir
                )
            except Error as e:
                log(f"could not resolve {', '.join(canonical)}: {e}")
                entry["error"] = str(e)
                entry["packages"] = []
                continue
            records = []
            for package in packages:
                if source_kind(package)[0] != "registry":
                    raise Error(
                        f"the build requirement {package['name']} resolved to a {source_kind(package)[0]} source; "
                        "build requirements come from an index"
                    )
                record = {"name": package["name"], "version": package["version"]}
                record["wheels"] = [add_artifact(w) for w in package.get("wheels", [])]
                if "sdist" in package:
                    record["sdist"] = add_artifact(package["sdist"])
                records.append(record)
                key = package_key(package)
                if key not in seen and key not in builds and may_need_build(package):
                    seen.add(key)
                    downloaded = download(package["sdist"]["url"], package["sdist"]["hash"], workdir)
                    request_tree(key, unpack(downloaded, workdir), workdir)
            entry["packages"] = records

    result = {
        "version": FORMAT_VERSION,
        "inputsHash": inputs_hash(root, tree_dirs),
        "artifacts": [artifacts[k] for k in sorted(artifacts)],
        "buildRequirements": requirement_sets,
        "builds": dict(sorted(builds.items())),
        "sources": dict(sorted(sources.items())),
    }
    with open(os.path.join(root, LOCK_FILE), "w") as f:
        json.dump(result, f, indent=2)
        f.write("\n")
    log(
        f"wrote {LOCK_FILE}: {len(builds)} builds, {len(requirement_sets)} sets of build requirements"
    )


def built_members(root):
    """The workspace members that have a build, which `publish` uploads."""
    with open(os.path.join(root, "uv.lock"), "rb") as f:
        uv_lock = tomllib.load(f)
    members = workspace_members(uv_lock)
    return [
        p["name"]
        for p in uv_lock.get("package", [])
        if p["name"] in members and source_kind(p)[0] != "virtual"
    ]


def nix_build(root, package=None):
    """Builds, with the Nix library this program was installed with, a
    member's package (its sdist and wheel), or without `package` the inputs
    of a development environment. Returns the store path."""
    library = os.environ.get("UV_PURIFIER_NIX_LIB")
    nixpkgs = os.environ.get("UV_PURIFIER_NIXPKGS")
    if not library or not nixpkgs:
        raise Error("this command needs the uv-purifier package, which sets UV_PURIFIER_NIX_LIB and UV_PURIFIER_NIXPKGS")
    args = [
        "nix-build",
        "--no-out-link",
        os.path.join(library, "cli.nix"),
        "--arg", "nixpkgs", nixpkgs,
        "--argstr", "src", root,
    ]
    if package is not None:
        args += ["--argstr", "package", package]
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, check=False)
    if result.returncode != 0:
        raise Error(f"the Nix build of {package or 'the development environment'} failed")
    return result.stdout.strip().splitlines()[-1]


def editable_trees(root):
    """The source trees `sync` installs as editable: every workspace member
    with a build, and every editable path dependency."""
    with open(os.path.join(root, "uv.lock"), "rb") as f:
        uv_lock = tomllib.load(f)
    members = workspace_members(uv_lock)
    trees = []
    for package in uv_lock.get("package", []):
        kind, value = source_kind(package)
        if kind == "editable" or (kind == "directory" and package["name"] in members):
            trees.append(value)
    return trees


def sync(root, inputs=None):
    """Installs the project's .venv offline, from the locked files that Nix
    fetched and built: the dependencies with their hashes, the packages from
    git, URLs and local paths from their wheels, and the workspace members
    and editable path dependencies as editable installs."""
    if inputs is None:
        log("building the locked files with Nix")
        inputs = nix_build(root)
    environment = dict(
        os.environ,
        UV_OFFLINE="1",
        UV_NO_INDEX="1",
        UV_FIND_LINKS=os.path.join(inputs, "wheelhouse"),
        UV_PYTHON_DOWNLOADS="never",
    )
    venv = os.environ.get("UV_PROJECT_ENVIRONMENT", os.path.join(root, ".venv"))
    python = os.path.join(venv, "bin", "python")

    def uv(*args):
        result = subprocess.run(["uv", *args], cwd=root, env=environment, check=False)
        if result.returncode != 0:
            raise Error(f"`uv {' '.join(args)}` failed")

    with tempfile.TemporaryDirectory(prefix="uv-purifier-") as workdir:
        exported = os.path.join(workdir, "exported.txt")
        requirements = os.path.join(workdir, "requirements.txt")
        wheels = os.path.join(workdir, "wheels.txt")
        uv("export", "--frozen", "--all-packages", "--no-emit-workspace",
           "--format", "requirements.txt", "--output-file", exported)
        result = subprocess.run(
            [sys.executable, "-I", os.path.join(inputs, "split_requirements.py"),
             exported, os.path.join(inputs, "direct.json"), requirements, wheels],
            check=False,
        )
        if result.returncode != 0:
            raise Error("splitting the exported requirements failed")
        if not os.path.exists(python):
            uv("venv", "--python", os.path.join(inputs, "python"), venv)
        uv("pip", "sync", "--python", python, "--require-hashes", requirements)
        with open(wheels) as f:
            for directory in f.read().split():
                files = [
                    os.path.join(directory, n)
                    for n in sorted(os.listdir(directory))
                    if n.endswith(".whl")
                ]
                uv("pip", "install", "--python", python, "--no-deps", *files)
        trees = editable_trees(root)
        if trees:
            editables = [a for tree in trees for a in ("--editable", tree)]
            uv("pip", "install", "--python", python, "--no-deps", *editables)
    log(f"installed {venv}; run commands in it with `uv run --no-sync`")


def publish(root, packages, uv_publish_args):
    members = built_members(root)
    for package in packages:
        if package not in members:
            raise Error(f"{package} is not a workspace member with a build; the members are {', '.join(members)}")
    files = []
    for package in packages or members:
        log(f"building {package} with Nix")
        out = nix_build(root, package)
        files += [
            os.path.join(out, name)
            for name in sorted(os.listdir(out))
            if name.endswith((".whl", ".tar.gz", ".zip"))
        ]
    result = subprocess.run(["uv", "publish", *uv_publish_args, *files], cwd=root, check=False)
    if result.returncode != 0:
        raise Error("uv publish failed")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="uv-purifier", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    lock_parser = sub.add_parser("lock", help=f"write {LOCK_FILE} beside uv.lock")
    lock_parser.add_argument("--project", default=".", help="the directory that holds uv.lock")
    publish_parser = sub.add_parser(
        "publish",
        help="build workspace members with Nix and upload what Nix built with `uv publish`",
    )
    publish_parser.add_argument("--project", default=".", help="the directory that holds uv.lock")
    publish_parser.add_argument(
        "--package",
        action="append",
        default=[],
        help="a workspace member to publish (repeatable; every member with a build when absent)",
    )
    publish_parser.add_argument(
        "uv_publish_args",
        nargs=argparse.REMAINDER,
        help="arguments for `uv publish`, after `--`",
    )
    sync_parser = sub.add_parser(
        "sync",
        help="install the project's .venv offline from the locked files, with the members editable",
    )
    sync_parser.add_argument("--project", default=".", help="the directory that holds uv.lock")
    sync_parser.add_argument(
        "--inputs",
        help="the inputs Nix built for the project (the `interactive` output of buildUvProject); "
        "built with Nix when absent",
    )
    args = parser.parse_args(argv)
    try:
        if args.command == "lock":
            lock(os.path.abspath(args.project))
        elif args.command == "sync":
            sync(os.path.abspath(args.project), args.inputs)
        elif args.command == "publish":
            extra = args.uv_publish_args
            if extra and extra[0] == "--":
                extra = extra[1:]
            publish(os.path.abspath(args.project), args.package, extra)
    except Error as e:
        log(str(e))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
