# The appliance's read-only store: a squashfs PARTITION as the lower layer, overlaid and
# registered by the shared roStore tool. A tmpfs root completes the memory-rooted shape.
# The mechanism belongs to whoever declares the read-only store — here, this module — and it
# is the same one the netboot and iso faces use.
#
# `device` defaults to the image's store partition, found by the label the image stamps
# (tools.diskLabels.store, passed in as storeLabel) — so an appliance whose runtime store IS
# that partition never restates the label the image chose, and the two cannot drift. A
# consumer whose store lives elsewhere passes `device` explicitly.
{ roStore, storeLabel, device ? "/dev/disk/by-partlabel/${storeLabel}" }:
{ lib, config, ... }@args:
lib.mkMerge [
  (roStore args {
    inherit device;
    fsType = "squashfs";
    options = [ "ro" ];
    priority = null;  # the host's OWN runtime store — a live face overrides it at 60
  })
  {
    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
      options = [ "mode=0755" ];
    };
  }
]
