# SPDX-License-Identifier: MIT
#
# The `uv-purifier` library namespace. It holds nothing: the builder needs
# a package set, so it is the package `buildUvProject` that the default
# package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    uv-purifier = prev.uv-purifier or { };
  };

}
