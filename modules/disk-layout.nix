# The disk layout TEMPLATE, for a host that has to own a disk but has nothing particular
# to say about it: GPT on one disk — an ESP at /boot, a vfat SLOT partition, and an ext4
# root taking the rest.
#
# It is an ordinary disko layout, imported in the host's own configuration alongside
# disko's module, and overridden there like any other option. Having it makes the host a
# disko host — nothing about the install is special-cased for it: disko's own create script
# formats and mounts the target, exactly as it does for a layout written by hand.
#
# `device` is the target's stable identity (/dev/disk/by-id/…) and the install's blast
# radius; `slotName` is the slot partition's partlabel, and the host record must name the
# same slot.
{ device, slotName, espSize ? "512M", slotSize ? "8M" }:
{ lib, ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = espSize;
          type = "EF00";
          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; };
        };
        nixos = {
          size = "100%";
          content = { type = "filesystem"; format = "ext4"; mountpoint = "/"; };
        };
        ${slotName} = {
          size = slotSize;
          # disko's default GPT name is disk-<disk>-<partition>, and the slot contract is
          # the partition NAMED slotName — found by that name on the target.
          label = slotName;
          content = { type = "filesystem"; format = "vfat"; };
        };
      };
    };
  };
  boot.loader.systemd-boot.enable = lib.mkDefault true;
}
