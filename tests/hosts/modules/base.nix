# The floor every test host stands on: minimal, serial-consoled, virtio-ready. Small on
# purpose — the closure is copied into every image these hosts produce.
{ modulesPath, ... }:
{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
  ];
  system.stateVersion = "26.05";
  boot.loader.grub.enable = false;
  boot.kernelParams = [ "console=ttyS0" ];
  networking.useDHCP = false;
  nix.enable = false;
  system.switch.enable = false;
  users.allowNoPasswordLogin = true;
}
