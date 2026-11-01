# SPDX-License-Identifier: MIT
#
# The fetcher for locked files.
#
# By default each file is a fixed-output derivation on Nix's built-in
# fetcher (the same derivation <nix/fetchurl.nix> makes). A fixed-output
# store path depends only on its name and hash, so the default fetcher and
# nixpkgs' fetchurl produce the same paths.
#
# `fetchurl`, when given, replaces the built-in fetcher. It is called with
# { name, url, hash } and is the place for credentials (nixpkgs' fetchurl
# takes `netrcPhase`) or mirrors.
{
  fetchurl ? null,
}:
# `hash` is the SRI hash of the file.
{
  name,
  url,
  hash,
}:
if fetchurl != null then
  fetchurl { inherit name url hash; }
else
  derivation {
    inherit name url;
    builder = "builtin:fetchurl";
    system = "builtin";
    urls = [ url ];
    outputHash = hash;
    outputHashAlgo = "sha256";
    outputHashMode = "flat";
    unpack = false;
    executable = false;
    preferLocalBuild = true;
    impureEnvVars = [
      "http_proxy"
      "https_proxy"
      "ftp_proxy"
      "all_proxy"
      "no_proxy"
    ];
  }
