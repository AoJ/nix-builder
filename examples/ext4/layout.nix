# A disko layout with the slot: GPT on one disk — ESP (/boot), ext4 root (/), and a vfat
# SLOT partition. disko turns this into diskoScript (create+mount) and mountScript, and
# sets fileSystems, so one declaration both formats the target at install and mounts it
# at runtime.
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
          # The slot: formatted vfat, no mountpoint — phase 2 writes it, the running
          # system mounts it on demand. The label is load-bearing: disko's default GPT
          # name is disk-<disk>-<partition>, and the slot contract is the partition
          # NAMED ${slotName}, found by that name.
          size = "8M";
          label = slotName;
          content = { type = "filesystem"; format = "vfat"; };
        };
      };
    };
  };
  boot.loader.systemd-boot.enable = true;
}
