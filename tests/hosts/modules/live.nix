# The memory-rooted VARIANT a live format packs: the composer applies this over the host's
# own configuration (the real extendModules step). The root becomes a tmpfs and the host's
# disk declaration simply stops applying — L1's "a ZFS host's ISO does not use the host's
# storage declaration" is this mkForce.
{ lib, pkgs, ... }:
{
  fileSystems = lib.mkForce {
    "/" = {
      device = "none";
      fsType = "tmpfs";
      options = [ "mode=0755" ];
    };
  };
  boot.kernelParams = [ "boot.live" ];
  boot.postBootCommands = ''
    if [ -e /nix/store/nix-path-registration ] && [ ! -e /nix/var/nix/db/db.sqlite ]; then
      ${pkgs.nix}/bin/nix-store --load-db < /nix/store/nix-path-registration
    fi
  '';
}
