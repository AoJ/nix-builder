{ lib, config, pkgs, tools, ... }:

let
  inherit (lib) mkOption types;

  esp = import ./parts/esp.nix { inherit pkgs lib tools; };
  iso = import ./parts/iso.nix { inherit pkgs lib; inherit (tools) ids storeFileName; };
  netboot = import ./parts/netboot.nix { inherit pkgs lib; inherit (tools) ids storeFileName; };
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
      type = types.enum [ "ext4" "squashfs" "zfs" ];
      description = "Picked by the composer, which knows the format it is asking for; validated here.";
    };

    storePlacement = mkOption {
      type = types.nullOr (types.enum [ "partition" "initrd" ]);
      description = ''
        Where the store rides in a DISK format: its own partition (the disk stays the store
        medium), or inside the initrd on the ESP (the booted system lives fully in RAM and
        holds no claim on any disk). Required for raw/qcow2; null for the formats whose
        placement is fixed by what they are.
      '';
    };

    layout = mkOption {
      type = types.nullOr types.raw;
      default = null;
      description = ''
        The host's disko layout, as DATA ({ disko.devices = …; }) — read by the disk
        formats whose store shape needs a kernel to make (zfs always; ext4 when the host
        declares a layout): the format-VM formats a blank disk from it and the closure is
        injected with no target-arch execution. Null falls back to userspace assembly.
      '';
    };

    hostId = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The target's networking.hostId — a zpool is born with it (no import -f).";
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
          label = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              The volume label the WHOLE medium is found by at /dev/disk/by-label/ — set
              for iso, whose consumer mounts the medium itself (the name-derived volume id,
              uppercased). Null for the disk formats, which are found by their PARTITION
              labels (ESP, nixos, the slot's name) instead, and for the netboot trees.
            '';
          };
          volumeId = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "The medium's 32-bit volume id (iso only) — the label, for a by-uuid consumer.";
          };
          parts = mkOption {
            type = types.nullOr (types.attrsOf types.unspecified);
            default = null;
            description = ''
              The pieces this disk is made of, for a consumer that assembles the same disk
              somewhere this block cannot reach — on a target whose size is only known
              there. Null for the formats that are not a disk.
            '';
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
        raw = [ "ext4" "squashfs" "zfs" ];
        qcow2 = [ "ext4" "squashfs" "zfs" ];
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
      diskFormat = config.format == "raw" || config.format == "qcow2";
      placement =
        if diskFormat && config.storePlacement == null
        then throw "image ${config.name}: ${config.format} must state where the store rides (storePlacement)"
        else if !diskFormat && config.storePlacement != null
        then throw "image ${config.name}: ${config.format} fixes its store placement — do not state one"
        else if config.storePlacement == "initrd"
          && (config.storeShape != "squashfs" || config.rootMode != "memory")
        then throw "image ${config.name}: an initrd-carried store is squashfs and memory-rooted"
        else config.storePlacement;
      # seq: the placement check must fire for EVERY format, including the ones whose
      # assembly never reads the placement.
      shape =
        if !builtins.elem config.storeShape legal.${config.format}
        then throw "image ${config.name}: a ${config.storeShape} store cannot ride in ${config.format}"
        else if !builtins.elem config.rootMode legalRoot.${config.format}
        then throw "image ${config.name}: a ${config.rootMode}-rooted system cannot boot from ${config.format}"
        else builtins.seq placement config.storeShape;

      store = tools.store {
        inherit (config) name;
        rootPaths = config.storePaths;
        inherit shape;
        label = tools.diskLabels.store;
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

      espPart = esp {
        inherit (config) name system;
        bootloader = config.espBinary;
        entries = [{
          name = "nixos";
          title = config.name;
          inherit (config) kernel initrd kernelParams;
        }];
      };
      espImg = espPart.img;

      # The kernel-made store shapes: a zfs disk cannot come out of userspace assembly, so
      # the format-VM makes it — disko formats a blank disk from the host's layout, and the
      # closure is injected as data. ext4 takes this path too when the host handed over a
      # layout (one layout for runtime, image and install); the wrappers, whose disk is
      # their own, never do and keep the assembly. The slot must be the LAYOUT's to give
      # here: this path adds no partitions, and a slot the layout does not label is a slot
      # personalize will never find.
      vmPath = diskFormat && placement == "partition"
        && (shape == "zfs" || (shape == "ext4" && config.layout != null));
      vmLayout =
        if config.layout == null
        then throw ("image ${config.name}: a ${shape} disk is formatted from the host's"
          + " disko layout and none was declared — deploy #image-${config.format}-install")
        else if config.slot != null && !lib.any
          (d: lib.any (p: (p.label or "") == config.slot.name)
            (lib.attrValues (d.content.partitions or { })))
          (lib.attrValues (config.layout.disko.devices.disk or { }))
        then throw ("image ${config.name}: the host asked for embedded delivery, but its"
          + " layout labels no '${config.slot.name}' partition for the slot")
        else config.layout;
      vmDisk = tools.formatVm {
        inherit (config) name hostId;
        layout = vmLayout;
        storePaths = config.storePaths;
        profile = config.toplevel;
        espFiles = espPart.files;
      };

      disk = tools.gptDisk {
        inherit (config) name;
        partitions = [
          { fs = "vfat"; label = tools.diskLabels.esp; img = espImg; }
          { fs = shape; label = tools.diskLabels.store; img = store.img; }
        ] ++ lib.optional (config.slot != null) {
          fs = "vfat"; code = "8300"; label = config.slot.name; img = slotImg;
        };
      };

      # The iso slot's path from the one source, not restated — the same slotFace the
      # installer reads and the marker gates against.
      slotFile = (tools.slotFace { format = "iso"; inherit (config.slot) name; }).path;

      # The iso medium's volume id, derived from the artifact name through the same ids tool
      # the iso part stamps with — one string, agreed on both sides (the e2e boot tests it).
      isoVolid = lib.toUpper (tools.ids.volumeId "${config.name}:iso");

      tree = netboot {
        inherit (config) name kernel initrd kernelParams;
        storeImg = store.img;
        slotName = if config.slot == null then null else config.slot.name;
      };

      # The initrd-carried disk: the netboot payload behind an ESP. Nothing but the ESP and
      # the slot is on the disk — the store rides the initrd, so the booted system holds no
      # claim on the medium it started from. The slot is the partition (personalize's raw
      # path), so the tree carries no marker segment.
      treeInmemory = netboot {
        inherit (config) name kernel initrd kernelParams;
        storeImg = store.img;
        slotName = null;
      };
      espInmemory = (esp {
        inherit (config) name system;
        bootloader = config.espBinary;
        entries = [{
          name = "nixos";
          title = config.name;
          kernel = "${treeInmemory}/kernel";
          initrd = "${treeInmemory}/initrd";
          inherit (config) kernelParams;
        }];
      }).img;
      diskInmemory = tools.gptDisk {
        inherit (config) name;
        partitions = [
          { fs = "vfat"; label = tools.diskLabels.esp; img = espInmemory; }
        ] ++ lib.optional (config.slot != null) {
          fs = "vfat"; code = "8300"; label = config.slot.name; img = slotImg;
        };
      };

      rawFile =
        if placement == "initrd" then diskInmemory
        else if vmPath then vmDisk
        else disk;

      byFormat = {
        raw = {
          file = rawFile;
          layout = rawFile.layout;
          slot = if config.slot == null then null
                 else { destination = "partition"; name = config.slot.name; fs = "vfat"; };
          # The same pieces this disk was built from, so the identical disk can be laid out
          # on a machine instead — with the store sized to the disk actually there.
          parts = {
            esp = espImg;
            storeLabel = "nixos";
            storeUuid = tools.ids.uuid "${config.name}:store";
            slotMiB = if config.slot == null then 0 else config.slot.sizeMiB;
          };
        };
        qcow2 = byFormat.raw // {
          file = pkgs.runCommand "${config.name}.qcow2"
            { nativeBuildInputs = [ pkgs.qemu-utils ]; }
            ''qemu-img convert -f raw -O qcow2 ${rawFile} "$out"'';
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
          # The medium's own volume id — the SAME string the iso part stamps as the volid,
          # derived here from the same name through the same ids tool, and handed back so a
          # consumer mounts by exactly what was written.
          label = isoVolid;
          volumeId = isoVolid;
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
