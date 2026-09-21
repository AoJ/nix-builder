# The zfs host's runtime facts (the layout template leaves enableConfig off, so the host
# states these): the pool's hostId, the zfs boot options, and the root/boot mounts. pool and
# espLabel are ARGUMENTS, the same values passed to the layout, so the mounts here and the
# partitions the layout makes cannot drift into a host that formats storage it cannot find.
# Required, no default: a default would be a second hidden source of a value that must agree
# with the layout.
{ pool, espLabel }:
{
  networking.hostId = "8425e349";
  boot.zfs.forceImportRoot = false;
  boot.supportedFilesystems = [ "zfs" ];
  # qemu virtio disks carry no by-id links; the pool's partition has a partlabel.
  boot.zfs.devNodes = "/dev/disk/by-partlabel";
  fileSystems."/" = {
    device = "${pool}/root";
    fsType = "zfs";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/${espLabel}";
    fsType = "vfat";
  };
  boot.loader.systemd-boot.enable = true;
}
