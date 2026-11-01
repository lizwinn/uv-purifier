# SPDX-License-Identifier: MIT
#
# Flask (github.com/pallets/flask), pinned to a commit, as an integration
# test on a real uv project: a flit-core build, 79 locked packages with
# compiled wheels (markupsafe, cffi, cryptography) and sdists to build, and
# dependency groups for tests, typing and docs.
#
# uv-purifier.lock.json beside this file is what `uv-purifier lock` wrote
# in a checkout of that commit. The check builds Flask's environment and
# package, then installs a development environment with `uv-purifier sync`
# and runs Flask's test suite in it, offline.
{
  pkgs,
  buildUvProject,
  cli,
}:
let
  upstream = pkgs.fetchFromGitHub {
    owner = "pallets";
    repo = "flask";
    rev = "49943b5a94413a530761350f04e896f76e8d620e";
    sha256 = "07ax2qyr3d7x7sayws07dv8dgbi9s8mrxj3lnlqwl6p0h417pvh7";
  };

  src = pkgs.runCommand "flask-source" { } ''
    cp -r ${upstream} $out
    chmod -R u+w $out
    cp ${./uv-purifier.lock.json} $out/uv-purifier.lock.json
  '';

  project = buildUvProject { inherit src; };
in
pkgs.runCommand "uv-purifier-test-flask"
  {
    nativeBuildInputs = [
      cli
      pkgs.uv
    ];
  }
  ''
    ${project.environments.flask.scripts.flask} --version
    test -f ${project.packages.flask.artifacts."flask-3.2.0.dev0-py3-none-any.whl"}
    test -f ${project.packages.flask.artifacts."flask-3.2.0.dev0.tar.gz"}

    cp -r ${src} flask
    chmod -R u+w flask
    cd flask
    export HOME=$TMPDIR UV_CACHE_DIR=$TMPDIR/uv-cache PYTHONDONTWRITEBYTECODE=1
    uv-purifier sync --inputs ${project.interactive}
    UV_OFFLINE=1 uv run --no-sync pytest -q -p no:cacheprovider
    touch $out
  ''
