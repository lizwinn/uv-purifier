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


def may_need_build(package):
    """Whether some platform may have to build this package from its sdist:
    it has an sdist and no wheel that installs everywhere. The Nix library
    decides per system and Python version which of these it actually builds,
    and fetches only their build requirements."""
    if "sdist" not in package:
        return False
    return not any(is_pure_wheel(file_name(w["url"])) for w in package.get("wheels", []))


def member_path(package):
    source = package.get("source", {})
    for kind in ("editable", "directory", "virtual"):
        if kind in source:
            return kind, source[kind]
    return None, None


def check_source(package):
    source = package.get("source", {})
    if "git" in source:
        raise Error(
            f"{package['name']} comes from git ({source['git']}); uv-purifier does not lock git sources yet"
        )
    if "path" in source:
        raise Error(
            f"{package['name']} comes from the local path {source['path']}; uv-purifier does not lock path sources yet"
        )


def build_requires(pyproject):
    build_system = pyproject.get("build-system")
    if build_system is None or "requires" not in build_system:
        return list(DEFAULT_BUILD_REQUIRES)
    return list(build_system["requires"])


def download(url, expected_uv_hash, directory):
    """Downloads a locked file and checks its hash."""
    target = os.path.join(directory, file_name(url))
    with urllib.request.urlopen(url) as response, open(target, "wb") as out:
        shutil.copyfileobj(response, out)
    algorithm, _, expected = expected_uv_hash.partition(":")
    actual = sha256_file(target)
    if algorithm != "sha256" or actual != expected:
        raise Error(f"{url} has sha256 {actual}, but the lock says {expected_uv_hash}")
    return target


def sdist_pyproject(path):
    """The pyproject.toml at the top of an sdist, or {} when it has none."""
    candidates = {}
    if path.endswith(".zip"):
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


def inputs_hash(root, member_dirs):
    """The hash the Nix library compares to tell whether the lockfile still
    matches uv.lock and the members' pyproject.toml files. nix/lib/lock.nix
    computes the same text."""
    files = ["uv.lock"] + sorted(
        "pyproject.toml" if d == "." else f"{d}/pyproject.toml" for d in member_dirs
    )
    text = "".join(f"{f} {sha256_file(os.path.join(root, f))}\n" for f in files)
    return hashlib.sha256(text.encode()).hexdigest()


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
    member_dirs = []

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

    with tempfile.TemporaryDirectory(prefix="uv-purifier-") as workdir:
        for package in uv_lock.get("package", []):
            kind, path = member_path(package)
            if kind is not None:
                member_dirs.append(path)
                if kind == "virtual":
                    continue
                with open(os.path.join(root, path, "pyproject.toml"), "rb") as f:
                    request(package_key(package), build_requires(tomllib.load(f)))
                continue
            check_source(package)
            if may_need_build(package):
                sdist = package["sdist"]
                log(f"reading the build requirements of {package['name']} {package['version']}")
                downloaded = download(sdist["url"], sdist["hash"], workdir)
                request(package_key(package), build_requires(sdist_pyproject(downloaded)))

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
                check_source(package)
                record = {"name": package["name"], "version": package["version"]}
                record["wheels"] = [add_artifact(w) for w in package.get("wheels", [])]
                if "sdist" in package:
                    record["sdist"] = add_artifact(package["sdist"])
                records.append(record)
                key = package_key(package)
                if key not in seen and key not in builds and may_need_build(package):
                    seen.add(key)
                    downloaded = download(package["sdist"]["url"], package["sdist"]["hash"], workdir)
                    request(key, build_requires(sdist_pyproject(downloaded)))
            entry["packages"] = records

    result = {
        "version": FORMAT_VERSION,
        "inputsHash": inputs_hash(root, member_dirs),
        "artifacts": [artifacts[k] for k in sorted(artifacts)],
        "buildRequirements": requirement_sets,
        "builds": dict(sorted(builds.items())),
    }
    with open(os.path.join(root, LOCK_FILE), "w") as f:
        json.dump(result, f, indent=2)
        f.write("\n")
    log(
        f"wrote {LOCK_FILE}: {len(builds)} builds, {len(requirement_sets)} sets of build requirements"
    )


def built_members(root):
    with open(os.path.join(root, "uv.lock"), "rb") as f:
        uv_lock = tomllib.load(f)
    return [
        p["name"]
        for p in uv_lock.get("package", [])
        if member_path(p)[0] in ("editable", "directory")
    ]


def nix_build_package(root, package):
    """Builds a member's package (its sdist and wheel) with the Nix library
    this program was installed with, and returns its store path."""
    library = os.environ.get("UV_PURIFIER_NIX_LIB")
    nixpkgs = os.environ.get("UV_PURIFIER_NIXPKGS")
    if not library or not nixpkgs:
        raise Error("publish needs the uv-purifier package, which sets UV_PURIFIER_NIX_LIB and UV_PURIFIER_NIXPKGS")
    result = subprocess.run(
        [
            "nix-build",
            "--no-out-link",
            os.path.join(library, "build-package.nix"),
            "--arg", "nixpkgs", nixpkgs,
            "--argstr", "src", root,
            "--argstr", "package", package,
        ],
        text=True,
        stdout=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise Error(f"the Nix build of {package} failed")
    return result.stdout.strip().splitlines()[-1]


def publish(root, packages, uv_publish_args):
    members = built_members(root)
    for package in packages:
        if package not in members:
            raise Error(f"{package} is not a workspace member with a build; the members are {', '.join(members)}")
    files = []
    for package in packages or members:
        log(f"building {package} with Nix")
        out = nix_build_package(root, package)
        files += [os.path.join(out, name) for name in sorted(os.listdir(out))]
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
    args = parser.parse_args(argv)
    try:
        if args.command == "lock":
            lock(os.path.abspath(args.project))
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
