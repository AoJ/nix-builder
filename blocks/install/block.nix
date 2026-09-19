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

    payload = mkOption {
      description = ''
        WHAT is delivered. An `image` is a finished disk written to the target as it is —
        what it holds is none of this block's business, so it delivers another operating
        system as well as a NixOS host. A `script` is a recipe that creates the target's
        storage, and the host's closure installed into it; the recipe is disko's own
        script, whether the host wrote the layout or took a template.
      '';
      type = types.submodule {
        options = {
          kind = mkOption { type = types.enum [ "image" "script" ]; };

          image = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "The disk to write, zstd-compressed; streamed to the disk, never unpacked to a file.";
          };

          toplevel = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "The system to install, and the kernel a kexec ending hands over to.";
          };

          storePaths = mkOption {
            type = types.listOf types.package;
            default = [ ];
            description = "What the installer carries, so it can install offline.";
          };

          script = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "Creates the target's storage and mounts it at /mnt. The block does not know its shape.";
          };
        };
      };
    };

    completion = mkOption {
      type = types.enum [ "reboot" "poweroff" "kexec" ];
      default = "reboot";
      description = ''
        How the machine leaves the install. `kexec` hands straight to what was just
        installed, which is the one ending a boot medium left in the machine cannot turn
        into a reinstall loop; `poweroff` stops and waits for someone to pull that medium;
        `reboot` goes through firmware again, for a machine that needs the cold start.
      '';
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

    encrypted = mkOption {
      type = types.bool;
      description = "Whether the target pool is encrypted — the storage layout's declaration (L3).";
    };

    slotName = mkOption {
      type = types.strMatching "[a-z0-9][a-z0-9-]*";
      description = ''
        The slot's name, on BOTH sides: the installer reads its own, and fills the one the
        target's layout provides under the same name. The installed system then finds its
        secrets exactly where it would have, had the image written the slot.
      '';
    };

    slotFiles = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        What the host declared its slot carries, by path. The act checks they arrived
        before it destroys anything — an installer nobody personalized must not wipe a
        disk and find out afterwards. Their contents are never read.
      '';
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
      p = config.payload;
      # A payload is refused here rather than half-understood later: each shape needs
      # exactly its own inputs, and a missing one would otherwise surface as an install
      # that starts and cannot finish.
      required = name: v:
        if v == null
        then throw "install(${config.name}): a ${p.kind} payload needs ${name}"
        else v;
      payload =
        if p.kind == "image" then {
          image = required "payload.image" p.image;
        }
        else {
          toplevel = required "payload.toplevel" p.toplevel;
          script = required "payload.script" p.script;
        };

      encrypted =
        if config.encrypted && config.storage != "zfs"
        then throw ("install(${config.name}): encryption is the zfs layout's property (L3)"
          + " — storage=${config.storage} cannot declare it")
        else if config.encrypted && p.kind == "image"
        then throw ("install(${config.name}): an image is written as it is, so nothing here"
          + " creates a pool to encrypt")
        else config.encrypted;

      # kexec hands over to the system that was just written, so its kernel has to be in
      # the INSTALLER's store — the target's is behind a filesystem this has no business
      # mounting. An image whose contents are not ours cannot be handed to.
      handover =
        if config.completion != "kexec" then null
        else if p.toplevel == null
        then throw ("install(${config.name}): completion=kexec needs payload.toplevel —"
          + " the kernel to hand over to has to be known, and an image alone does not say")
        else p.toplevel;

      # Forced here rather than left to whichever branch happens to read them: an image
      # delivery never looks at `encrypted`, so a refusal riding on that value alone would
      # fire for a closure and stay silent for an image.
      checked = builtins.seq encrypted (builtins.seq handover payload);

      installer = import (pkgs.path + "/nixos/lib/eval-config.nix") {
        inherit (config) system;
        modules = [
          (import ./installer-profile.nix {
            inherit (config) name pool storage rootMode isoLabel slotFace disks report
              machine slotName slotFiles completion;
            inherit encrypted payload handover;
            kind = p.kind;
            actionInstall = tools.actionInstall { inherit (config) storage; };
            inherit (tools) netbootFace isoFace;
          })
        ];
      };
      toplevel = installer.config.system.build.toplevel;
      efiArch = installer.pkgs.stdenv.hostPlatform.efiArch;
    in
    builtins.seq checked
    {
      inherit toplevel;
      kernel = "${toplevel}/kernel";
      initrd = "${toplevel}/initrd";
      kernelParams = installer.config.boot.kernelParams ++ [ "init=${toplevel}/init" ];
      # What the installer must CARRY: the image to write, or the closure to install —
      # plus, for a kexec ending, the kernel it hands over to.
      storePaths = [ toplevel ]
        ++ (if p.kind == "image" then [ payload.image ]
            else [ payload.toplevel ] ++ p.storePaths)
        ++ lib.optional (handover != null) handover;
      espBinary =
        "${installer.config.systemd.package}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
      rootMode = config.rootMode;
    };
}
