# A REAL disko ext4 layout: GPT on one disk with an ESP (/boot), an ext4 root (/), and a
# vfat SLOT partition. disko generates diskoScript (create+mount) and mountScript from this,
# and sets fileSystems — so the same layout formats the target at install and mounts it at
# runtime.
#
# `device` is the target's stable identity; `slotName` is the slot partition's partlabel —
# the host's one slot declaration, bound here and in the host record from the same value.
{ device, slotName }:
{
  disko.devices.disk.main = {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; };
        };
        nixos = {
          size = "100%";
          content = { type = "filesystem"; format = "ext4"; mountpoint = "/"; };
        };
        ${slotName} = {
          # The slot the layout provides: formatted vfat, no mountpoint — phase 2 writes it,
          # the running system mounts it on demand (the slot's runtime face). The label is
          # load-bearing: disko's default GPT name is disk-<disk>-<partition>, and the slot
          # contract is the partition NAMED ${slotName}, found by that name.
          size = "8M";
          label = slotName;
          content = { type = "filesystem"; format = "vfat"; };
        };
      };
    };
  };
  boot.loader.systemd-boot.enable = true;
}
