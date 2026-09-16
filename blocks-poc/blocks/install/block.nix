{ lib, config, pkgs, tools, ... }:

let
  inherit (lib) mkOption types;
in
{
  options = {
    name = mkOption { type = types.strMatching "[a-z0-9][a-z0-9-]*"; };

    system = mkOption {
      type = types.enum [ "x86_64-linux" "aarch64-linux" ];
      description = "Architecture the installer runs on — the target's, since it installs offline.";
    };

    toplevel = mkOption {
      type = types.package;
      description = "The system to be installed.";
    };

    closure = mkOption {
      type = types.listOf types.package;
      description = "What the installer carries, so it can install offline.";
    };

    prepare = mkOption {
      type = types.package;
      description = "Brings the target's storage into existence AND mounts it at /mnt. The block does not know its shape.";
    };

    mount = mkOption {
      type = types.package;
      description = "Mounts that storage at /mnt when it already exists — the never-reformat path.";
    };

    pool = mkOption {
      type = types.str;
      default = "";
      description = "The zfs pool the action probes and exports; empty for a plain filesystem.";
    };

    disks = mkOption {
      type = types.nonEmptyListOf types.str;
      description = "Block devices the target lives on — what a create wipes first, and only a create.";
    };

    machine = mkOption {
      type = types.submodule {
        options = {
          kernelPackages = mkOption { type = types.raw; };
          initrdAvailableKernelModules = mkOption { type = types.listOf types.str; };
          initrdKernelModules = mkOption { type = types.listOf types.str; };
          kernelModules = mkOption { type = types.listOf types.str; };
          firmware = mkOption { type = types.listOf types.package; };
        };
      };
      description = "The target machine as the host declares it — the installer boots exactly where the host boots.";
    };

    report = mkOption {
      type = types.nullOr types.str;
      description = "Executable the installer calls with one line per milestone; null reports nothing.";
    };

    storage = mkOption {
      type = types.enum [ "zfs" "ext4" ];
      description = "Shapes the action's probe and teardown — the one zfs-specific branch.";
    };

    keyDestination = mkOption {
      type = types.str;
      description = "Where the installed system's key lands, once the target exists.";
    };

    rootMode = mkOption {
      type = types.enum [ "disk" "memory" ];
      default = "disk";
      description = "How the INSTALLER is rooted: its own disk partition, or a memory face.";
    };

    isoLabel = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Set for the iso wrapper: the memory face becomes the iso face, keyed by this label.";
    };

    slotFace = mkOption {
      type = types.attrsOf types.str;
      description = "Where the installer reads its install-time key (tools.slotFace for the wrapper's format).";
    };

    out = mkOption {
      readOnly = true;
      type = types.submodule {
        options = {
          # The installer, in the extracted shape image consumes. It goes to image, which
          # does not know it is one.
          system = mkOption {
            type = types.submodule {
              options = {
                toplevel = mkOption { type = types.package; };
                kernel = mkOption { type = types.path; };
                initrd = mkOption { type = types.path; };
                kernelParams = mkOption { type = types.listOf types.str; };
                storePaths = mkOption { type = types.listOf types.package; };
                espBinary = mkOption { type = types.path; };
                rootMode = mkOption { type = types.enum [ "disk" "memory" ]; };
              };
            };
          };
        };
      };
    };
  };

  config.out.system =
    let
      installer = import (pkgs.path + "/nixos/lib/eval-config.nix") {
        inherit (config) system;
        modules = [
          (import ./installer-profile.nix {
            inherit (config) name prepare mount toplevel pool storage keyDestination rootMode
              isoLabel slotFace disks report machine;
            actionInstall = tools.actionInstall { inherit (config) storage; };
            actionWipe = tools.actionWipe { inherit (config) storage; };
            inherit (tools) netbootFace isoFace;
          })
        ];
      };
      toplevel = installer.config.system.build.toplevel;
      efiArch = installer.pkgs.stdenv.hostPlatform.efiArch;
    in
    {
      inherit toplevel;
      kernel = "${toplevel}/kernel";
      initrd = "${toplevel}/initrd";
      kernelParams = installer.config.boot.kernelParams ++ [ "init=${toplevel}/init" ];
      storePaths = [ toplevel ] ++ config.closure;
      espBinary =
        "${installer.config.systemd.package}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
      rootMode = config.rootMode;
    };
}
