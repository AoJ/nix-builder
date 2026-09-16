{ pkgs }:

# The one privileged place: it assembles the tool set that every block is handed, and it is
# the only spot that reaches outside blocks-poc (lib/bash-tool.nix + the bash helper lib it
# prepends). Only tools go in here. A block placed here would let a block reach a block,
# and the rule that keeps the dependency graph acyclic falls.
let
  inherit (pkgs) lib;
  bashTool = args: (import ../../lib/bash-tool.nix) ({ inherit pkgs; } // args);
  ids = import ./ids.nix;
  # zfs (userland here, the kernel module in the installer profile) rides only where the
  # target storage is zfs — an ext4 installer carries neither.
  actionWipe = { storage }: bashTool {
    name = "action-wipe";
    runtimeInputs = (with pkgs; [ util-linux gptfdisk parted mdadm coreutils systemd ])
      ++ lib.optional (storage == "zfs") pkgs.zfs;
    text = builtins.readFile ./action-wipe.sh;
  };
in
{
  inherit bashTool ids actionWipe;
  fatImage = (import ./fat-image.nix { inherit pkgs bashTool; }).build;
  fatImageApp = (import ./fat-image.nix { inherit pkgs bashTool; }).app;
  gptDisk = import ./gpt-disk.nix { inherit pkgs bashTool ids; };
  store = import ./store.nix { inherit pkgs bashTool; };
  actionInstall = { storage }: bashTool {
    name = "action-install";
    runtimeInputs = (with pkgs; [
      nix util-linux e2fsprogs dosfstools nixos-install-tools coreutils gawk
    ]) ++ [ (actionWipe { inherit storage; }) ]
      ++ lib.optional (storage == "zfs") pkgs.zfs;
    text = builtins.readFile ./action-install.sh;
  };
  # The read-only store mechanism (overlay + register-nix-paths) and the two runtime faces
  # built on it. A face is a nixos module, and the mechanism belongs to whoever declares the
  # read-only store — so it lives here once and every consumer imports it.
  roStore = import ./ro-store.nix { inherit pkgs; };
  netbootFace = import ./netboot-face.nix { inherit pkgs; };
  isoFace = import ./iso-face.nix { inherit pkgs; };
  # Where a slot lives per format — the ONE source the image builds from and the installer
  # reads from. (The marker restates it on purpose, to gate drift; see marker.nix.)
  slotFace = import ./slot-face.nix;
}
