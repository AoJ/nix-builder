# The runtime fileSystems for an ASSEMBLY ext4 host (no disko layout): root off the store
# partition, /boot off the ESP — both found by the labels the image STAMPS, passed in from
# tools.diskLabels so the host never restates a literal the image could rename out from
# under it. A disko host gets its fileSystems from the layout instead; this is the
# hand-declared path the layout-less hosts and the wrappers still take.
{ storeLabel, espLabel }:
{
  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/${storeLabel}";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/${espLabel}";
    fsType = "vfat";
  };
  # The image path never runs it — the artifact's ESP is the image block's. The INSTALL
  # path does: nixos-install writes the target's own bootloader through this.
  boot.loader.systemd-boot.enable = true;
}
