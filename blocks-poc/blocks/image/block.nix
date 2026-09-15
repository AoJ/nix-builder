{ lib, config, pkgs, tools, ... }:

let
  inherit (lib) mkOption types;

  esp = import ./parts/esp.nix { inherit pkgs lib tools; };
  iso = import ./parts/iso.nix { inherit pkgs lib; inherit (tools) ids; };
  netboot = import ./parts/netboot.nix { inherit pkgs lib; inherit (tools) ids; };
in
{
  options = {
    name = mkOption {
      type = types.strMatching "[a-z0-9][a-z0-9-]*";
      description = "What the artifact is called.";
    };

    format = mkOption {
      type = types.enum [ "iso" "raw" "qcow2" "kexec" "ipxe" ];
      description = "The shape the artifact is handed over in.";
    };

    system = mkOption {
      type = types.enum [ "x86_64-linux" "aarch64-linux" ];
      description = "Architecture the artifact boots on.";
    };

    toplevel = mkOption {
      type = types.package;
      description = "The toplevel being packed. Handed through, so #closure-live is a lookup.";
    };

    # Paths, not packages: the extraction hands over `${toplevel}/kernel` — a store SUBPATH
    # with context, which is a file, not a derivation.
    kernel = mkOption { type = types.path; };
    initrd = mkOption { type = types.path; };

    # From the TARGET's own systemd, extracted by the caller: this block's tools are the
    # runner's, and a runner-arch pkgs.systemd carries no aa64 binary at all.
    espBinary = mkOption { type = types.path; };

    rootMode = mkOption {
      type = types.enum [ "disk" "memory" ];
      description = "How the packed system is rooted; validated against the format.";
    };

    kernelParams = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    storePaths = mkOption {
      type = types.listOf types.package;
      description = "Roots whose closure the artifact carries.";
    };

    storeShape = mkOption {
      type = types.enum [ "ext4" "squashfs" ];
      description = "Picked by the composer, which knows the format it is asking for; validated here.";
    };

    slot = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          name = mkOption { type = types.strMatching "[a-z0-9][a-z0-9-]*"; };
          sizeMiB = mkOption { type = types.ints.positive; };
        };
      });
      default = null;
    };

    out = mkOption {
      readOnly = true;
      description = "What this block hands over.";
      type = types.submodule {
        options = {
          file = mkOption { type = types.package; };
          toplevel = mkOption { type = types.package; };
          layout = mkOption {
            type = types.nullOr types.package;
            description = "The partition layout as built, as JSON. Read it, do not restate it.";
          };
          slot = mkOption {
            type = types.nullOr (types.attrsOf types.str);
            description = "The artifact face, as built — what personalize consumes.";
          };
        };
      };
    };
  };

  config.out =
    let
      # The composer picked shape and root mode; a wrong composition fails HERE, at eval,
      # not at boot.
      legal = {
        raw = [ "ext4" "squashfs" ];
        qcow2 = [ "ext4" "squashfs" ];
        iso = [ "squashfs" ];
        kexec = [ "squashfs" ];
        ipxe = [ "squashfs" ];
      };
      legalRoot = {
        raw = [ "disk" "memory" ];
        qcow2 = [ "disk" "memory" ];
        iso = [ "memory" ];
        kexec = [ "memory" ];
        ipxe = [ "memory" ];
      };
      shape =
        if !builtins.elem config.storeShape legal.${config.format}
        then throw "image ${config.name}: a ${config.storeShape} store cannot ride in ${config.format}"
        else if !builtins.elem config.rootMode legalRoot.${config.format}
        then throw "image ${config.name}: a ${config.rootMode}-rooted system cannot boot from ${config.format}"
        else config.storeShape;

      store = tools.store {
        inherit (config) name;
        rootPaths = config.storePaths;
        inherit shape;
        label = "nixos";
        # A writable root is a bootable NixOS root, so it carries the profile links a first
        # switch reads; a read-only or initrd store is a store and nothing more.
        profile = if shape == "ext4" then config.toplevel else null;
      };

      slotImg = tools.fatImage {
        inherit (config) name;
        # Deliberately NOT a lookup handle: the slot is found by PARTLABEL or offset, and a
        # meaningful fs label here would collide with the sidecar's on any machine carrying
        # both — measured, udev's by-label picked the empty slot over the sidecar.
        label = "SLOT";
        volumeId = tools.ids.volumeId "${config.name}:slot";
        sizeMiB = config.slot.sizeMiB;
      };

      espImg = esp {
        inherit (config) name system;
        bootloader = config.espBinary;
        entries = [{
          name = "nixos";
          title = config.name;
          inherit (config) kernel initrd kernelParams;
        }];
      };

      disk = tools.gptDisk {
        inherit (config) name;
        partitions = [
          { fs = "vfat"; label = "ESP"; img = espImg; }
          { fs = shape; label = "nixos"; img = store.img; }
        ] ++ lib.optional (config.slot != null) {
          fs = "vfat"; code = "8300"; label = config.slot.name; img = slotImg;
        };
      };

      # The iso slot's path from the one source, not restated — the same slotFace the
      # installer reads and the marker gates against.
      slotFile = (tools.slotFace { format = "iso"; inherit (config.slot) name; }).path;

      tree = netboot {
        inherit (config) name kernel initrd kernelParams;
        storeImg = store.img;
        slotName = if config.slot == null then null else config.slot.name;
      };

      byFormat = {
        raw = {
          file = disk;
          layout = disk.layout;
          slot = if config.slot == null then null
                 else { destination = "partition"; name = config.slot.name; fs = "vfat"; };
        };
        qcow2 = byFormat.raw // {
          file = pkgs.runCommand "${config.name}.qcow2"
            { nativeBuildInputs = [ pkgs.qemu-utils ]; }
            ''qemu-img convert -f raw -O qcow2 ${disk} "$out"'';
        };
        iso = {
          file = iso {
            inherit (config) name;
            inherit espImg;
            storeImg = store.img;
            extraFiles = lib.optional (config.slot != null) {
              path = slotFile;
              source = slotImg;
            };
          };
          layout = null;
          slot = if config.slot == null then null
                 else { destination = "file"; path = slotFile; fs = "vfat"; };
        };
        kexec = {
          file = tree;
          layout = null;
          slot = if config.slot == null then null
                 else { destination = "initrd-append"; name = config.slot.name; };
        };
        ipxe = byFormat.kexec;
      };
    in
    byFormat.${config.format} // { inherit (config) toplevel; };
}
