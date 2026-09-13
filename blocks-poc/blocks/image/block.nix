{ lib, config, pkgs, tools, ... }:

let
  inherit (lib) mkOption types;

  esp = import ./parts/esp.nix { inherit pkgs lib; inherit (tools) ids; };
  gpt = import ./parts/gpt.nix { inherit pkgs lib; inherit (tools) ids; };
in
{
  options = {
    name = mkOption {
      type = types.strMatching "[a-z0-9][a-z0-9-]*";
      description = "What the artifact is called.";
    };

    format = mkOption {
      type = types.enum [ "raw" "qcow2" ];
      description = "The shape the artifact is handed over in.";
    };

    system = mkOption {
      type = types.enum [ "x86_64-linux" "aarch64-linux" ];
      description = "Architecture the artifact boots on.";
    };

    kernel = mkOption { type = types.package; };
    initrd = mkOption { type = types.package; };

    kernelParams = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    storePaths = mkOption {
      type = types.listOf types.package;
      description = "Roots whose closure the artifact carries.";
    };

    out = mkOption {
      readOnly = true;
      description = "What this block hands over.";
      type = types.submodule {
        options = {
          file = mkOption { type = types.package; };
          layout = mkOption {
            type = types.package;
            description = "The partition layout as built, as JSON. Read it, do not restate it.";
          };
        };
      };
    };
  };

  config.out =
    let
      store = tools.store {
        inherit (config) name;
        rootPaths = config.storePaths;
        shape = "ext4";
        label = "nixos";
      };

      bootEfi =
        if config.system == "x86_64-linux"
        then "${pkgs.systemd}/lib/systemd/boot/efi/systemd-bootx64.efi"
        else "${pkgs.systemd}/lib/systemd/boot/efi/systemd-bootaa64.efi";

      disk = gpt {
        inherit (config) name;
        partitions = [
          { fs = "vfat"; label = "ESP"; img = esp {
              inherit (config) name system;
              bootloader = bootEfi;
              entries = [{
                name = "nixos";
                title = config.name;
                inherit (config) kernel initrd kernelParams;
              }];
            };
          }
          { fs = "ext4"; label = "nixos"; img = store.img; }
        ];
      };
    in
    {
      layout = disk.layout;
      file =
        if config.format == "raw" then disk
        else pkgs.runCommand "${config.name}.qcow2"
          { nativeBuildInputs = [ pkgs.qemu-utils ]; }
          ''qemu-img convert -f raw -O qcow2 ${disk} "$out"'';
    };
}
