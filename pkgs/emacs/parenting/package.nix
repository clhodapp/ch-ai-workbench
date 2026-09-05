# SPDX-License-Identifier: MIT
# parenting, built from the `parenting` flake input: a plain Emacs package
# repository (github:clhodapp/parenting), not a flake. The version carries
# the pinned commit's date; the pin advances with the other external
# inputs.
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
  pname = "parenting";
  version = "0.1.0-unstable-${isoDate}";
  inherit src;

  meta = {
    homepage = "https://github.com/clhodapp/parenting";
    description = "Remote-control one Emacs from another over a private socket";
    license = lib.licenses.gpl3Plus;
  };
}
