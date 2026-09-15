# The embedded slot's naming policy — a composer-level decision, not a mechanism (so not in
# tools) and not a block's to know (blocks receive it as input). One source: the image
# builds the partition/file from `name`, and the runtime consumers (marker, installer) read
# `file` back off the medium instead of restating "/boot/secrets.img". compose.nix imports
# it and hands it to the install block; the tests import it for the marker.
let
  name = "secrets";
in
{
  inherit name;
  file = "/boot/${name}.img";
}
