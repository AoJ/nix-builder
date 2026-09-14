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
      description = "The pool the install action probes and cleanly exports.";
    };

    keyDestination = mkOption {
      type = types.str;
      description = "Where the installed system's key lands, once the target exists.";
    };

    rootMode = mkOption {
      type = types.enum [ "disk" "memory" ];
      default = "disk";
      description = "How the INSTALLER is rooted. The memory variant does not exist yet and refuses.";
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
      installer =
        # The same named-hole discipline as L2: a hole the eval names, never a green
        # artifact that cannot boot.
        if config.rootMode == "memory"
        then throw ("install ${config.name}: the memory-rooted installer does not exist yet"
          + " — iso/kexec/ipxe install wrappers wait on it")
        else import (pkgs.path + "/nixos/lib/eval-config.nix") {
          inherit (config) system;
          modules = [
            (import ./installer-profile.nix {
              inherit (config) name prepare mount toplevel pool keyDestination;
              inherit (tools) niximilateInstall;
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
