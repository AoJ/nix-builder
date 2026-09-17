# The appliance's read-only store: a squashfs PARTITION as the lower layer, overlaid and
# registered by the shared roStore tool. A tmpfs root completes the memory-rooted shape.
# The mechanism belongs to whoever declares the read-only store — here, this module — and it
# is the same one the netboot and iso faces use.
{ roStore, device }:
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
