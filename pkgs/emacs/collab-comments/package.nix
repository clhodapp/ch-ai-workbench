# SPDX-License-Identifier: MIT
# collab-comments, built from the `collab-comments` flake input: a plain
# Emacs package repository (github:clhodapp/collab-comments), not a flake.
# The version carries the pinned commit's date; the pin advances with the
# other external inputs.
{
  lib,
  melpaBuild,
  src,
}:
let
  date = src.lastModifiedDate;
  isoDate = "${lib.substring 0 4 date}-${lib.substring 4 2 date}-${lib.substring 6 2 date}";
in
melpaBuild {
  pname = "collab-comments";
  version = "0.1.0-unstable-${isoDate}";
  inherit src;

  meta = {
    homepage = "https://github.com/clhodapp/collab-comments";
    description = "Comment threads on buffer text, shared with agents";
    license = lib.licenses.gpl3Plus;
  };
}
