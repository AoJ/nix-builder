{ lib, config, pkgs, ... }:

let
  inherit (lib) mkOption types;

  esp = import ./parts/esp.nix { inherit pkgs lib; };
  gpt = import ./parts/gpt.nix { inherit pkgs lib; };
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
      closure = pkgs.closureInfo { rootPaths = config.storePaths; };

      root = pkgs.runCommand "root.img"
        { nativeBuildInputs = [ pkgs.e2fsprogs pkgs.fakeroot pkgs.coreutils ]; }
        ''
          set -euo pipefail
          staged="$(mktemp -d)"
          mkdir -p "$staged/nix/store"
          while IFS= read -r p; do
            cp -a --reflink=auto "$p" "$staged/nix/store/"
          done < ${closure}/store-paths
          cp ${closure}/registration "$staged/nix/store/.registration"

          # A store tree is many small files: the default inode ratio runs out long
          # before the space does, and du reports ALLOCATED blocks, so both numbers
          # are computed from the tree itself with room to spare.
          files="$(find "$staged" | wc -l)"
          kib="$(du -sk --apparent-size "$staged" | cut -f1)"
          size_mib=$(( kib / 1024 + kib / 4096 + 128 ))

          truncate -s "''${size_mib}M" "$out"
          # -E no_copy_xattrs: on a SELinux host mke2fs reads security.selinux off the
          # staged tree and aborts. The label has no meaning inside the image anyway.
          fakeroot mke2fs -t ext4 -b 4096 -L nixos -E no_copy_xattrs \
            -N "$(( files * 2 + 4096 ))" \
            -U deadbeef-dead-beef-dead-beefdeadbeef \
            -d "$staged" "$out"
        '';

      bootEfi =
        if config.system == "x86_64-linux"
        then "${pkgs.systemd}/lib/systemd/boot/efi/systemd-bootx64.efi"
        else "${pkgs.systemd}/lib/systemd/boot/efi/systemd-bootaa64.efi";

      disk = gpt {
        inherit (config) name;
        partitions = [
          { fs = "vfat"; label = "ESP"; img = esp {
              inherit (config) system;
              bootloader = bootEfi;
              entries = [{
                name = "nixos";
                title = config.name;
                inherit (config) kernel initrd kernelParams;
              }];
            };
          }
          { fs = "ext4"; label = "nixos"; img = root; }
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
