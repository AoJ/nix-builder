# The vfat "result" disk support: vfat in the kernel, and the shared recorder on PATH so
# any service can append its witness. The harness attaches the disk and reads it after qemu
# exits — see tools/e2eRecord.
{ record }:
{ pkgs, ... }:
{
  boot.kernelModules = [ "vfat" ];
  environment.systemPackages = [ record ];
}
