# The read-only store, and the unit that belongs to it. A configuration that says
# /nix/store is a squashfs does not work without the database load, the way a mount does
# not work without a filesystem — so both halves live in ONE module, and the constant path
# they agree on is nixpkgs' own (make-squashfs.nix writes it, netboot.nix reads it).
{ device }:
{ pkgs, ... }:
{
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "mode=0755" ];
  };
  fileSystems."/nix/store" = {
    inherit device;
    fsType = "squashfs";
    options = [ "ro" ];
    neededForBoot = true;
  };
  boot.postBootCommands = ''
    if [ -e /nix/store/nix-path-registration ] && [ ! -e /nix/var/nix/db/db.sqlite ]; then
      ${pkgs.nix}/bin/nix-store --load-db < /nix/store/nix-path-registration
    fi
  '';
}
