# The composer: the ONE place that knows the host. Blocks never see it and never see each
# other; everything a block receives is derivations and strings extracted here.
{ pkgs, tools }:

let
  inherit (pkgs) lib;

  image = import ./blocks/image { inherit pkgs tools; };
  install = import ./blocks/install { inherit pkgs tools; };
  secrets = import ./blocks/secrets { inherit pkgs tools; };
  personalize = import ./blocks/personalize { inherit pkgs tools; };

  formats = [ "iso" "raw" "qcow2" "kexec" "ipxe" ];
  liveFormats = [ "iso" "kexec" "ipxe" ];
in

rawHost:

let
  # The record goes through its option interface before anything reads it (see
  # lib/host-record.nix): a missing field, a typo'd name or a wrong type is named HERE,
  # not met as an attribute error somewhere inside a block. Required fields stay lazy, so
  # a host that never reaches an endpoint needing one never trips over it.
  host = (lib.evalModules {
    modules = [ (import ./lib/host-record.nix { inherit lib; }) rawHost ];
  }).config;

  # The slot exists only where there is something to put in it: a host that declares no
  # secrets needs no slot, builds no slot partition, and need not name one. A host that DOES
  # declare secrets must name it (never a default — the name has to match its layout's
  # partition, and a default would be a second hidden source of that word).
  hasSlot = host.secrets.files != [ ];
  slotName =
    if !hasSlot then null
    else if host.slotName == null
    then throw ("imagesFor(${host.name}): this host delivers secrets but names no slot"
      + " — set slotName to the same name its storage layout gives the slot partition")
    else host.slotName;
  slot = if slotName == null then null else { name = slotName; sizeMiB = 4; };

  # The label is the one constant spanning eval and artifact: both sides derive it from
  # the same name through the same ids tool, and the e2e boot tests the agreement.
  isoLabel = lib.toUpper (tools.ids.volumeId "${host.name}-iso:iso");
  variantFor = format:
    if format == "iso" then host.variants.liveIso isoLabel
    else if format == "kexec" || format == "ipxe" then host.variants.liveNetboot
    else host.variants.runtime;

  extract = v: {
    inherit (v) toplevel kernel initrd kernelParams espBinary rootMode;
    storePaths = [ v.toplevel ];
  };

  # L2 as amended: an unencrypted pool is created by the format-VM from the host's disko
  # layout; the ENCRYPTED pool stays the install's alone (L3) — every key the image build
  # could use is store-public for life.
  diskShape =
    if host.variants.runtime.storage == "zfs" && (host.install.encrypted or false)
    then throw ("unsupported (L3): an encrypted pool cannot be created from store-public"
      + " data — use #image-<format>-install")
    else host.variants.runtime.storage;
  storeShapeFor = format: {
    iso = "squashfs";
    kexec = "squashfs";
    ipxe = "squashfs";
    raw = diskShape;
    qcow2 = diskShape;
  }.${format};

  # Disk formats carry their store in a partition unless an endpoint says otherwise; the
  # other formats fix their own placement and take none.
  placementFor = format:
    if format == "raw" || format == "qcow2" then "partition" else null;

  # The installer is an OS of its own; its store and root mode are the WRAPPER's, so the
  # target's storage never shapes them and the L2 hole does not exist on the -install half.
  installerShapeFor = format: {
    iso = "squashfs";
    kexec = "squashfs";
    ipxe = "squashfs";
    raw = "ext4";
    qcow2 = "ext4";
  }.${format};
  installerRootModeFor = format:
    if builtins.elem format liveFormats then "memory" else "disk";

  # A declared delivery must have a producer; a member nobody produces fails at eval
  # instead of leaving a host to boot without an identity.
  producers = [ "embedded" "sidecar" ];
  delivery =
    let missing = lib.subtractLists producers host.secrets.delivery;
    in
    if missing == [ ]
    then host.secrets.delivery
    else throw "no producer for secrets.delivery ${builtins.toJSON missing}";

  # The extractor seam for the slot: composed from the host's declared deliveries today; a
  # storage layout that owns a shape would be READ here, not consulted by a block.
  slotFor = _format:
    if slot != null && builtins.elem "embedded" delivery
    then { inherit (slot) name; sizeMiB = 4; }
    else null;

  imageFor = format: shape: rootMode: system: nameSuffix: placement: extras:
    image ({
      name = "${host.name}-${format}${nameSuffix}";
      inherit format;
      inherit (host) system;
      storeShape = shape;
      storePlacement = placement;
      slot = slotFor format;
    } // extract system // { inherit rootMode; } // extras);

  # The runtime disk endpoints carry the host's OWN layout and hostid — the format-VM's
  # inputs; the wrapper endpoints never do, an installer's disk is the wrapper's.
  runtimeEndpoints = lib.listToAttrs (map (f: rec {
    name = "image-${f}";
    value =
      let v = variantFor f;
      in imageFor f (storeShapeFor f) v.rootMode v "" (placementFor f) {
        layout = host.layout or null;
        hostId = host.hostId or null;
        # The iso medium's label, derived ONCE here and handed to the block — the same
        # string the runtime iso face mounts by.
        mediumLabel = if f == "iso" then isoLabel else null;
      };
  }) formats);

  # What gets installed is ALWAYS the host as it runs; the format only shapes the wrapper.
  # The iso wrapper's installer wears the iso face, keyed by the label derived from the
  # `-iso-install` artifact name through the same ids tool the image block uses.
  isoInstallLabel = lib.toUpper (tools.ids.volumeId "${host.name}-iso-install:iso");
  # The installer reads its install-time key from its OWN slot, whose shape is the
  # WRAPPER's: a disk wrapper from a partition (whichever way the installer roots), an iso
  # from the medium's file, a netboot from the initrd hand-over.
  # WHAT the install delivers. Derived, because the host already said everything needed to
  # decide: a host whose storage no image can hold states a recipe for it, and that recipe
  # is the only reason to carry a closure and install onto storage created on the spot.
  # Everyone else gets their own disk image written as it is. A host may say `payload`
  # itself to override — that is how a finished image from elsewhere, or another operating
  # system entirely, is delivered by the same act.
  compressedImage = raw: pkgs.runCommand "${host.name}-payload.img.zst"
    { nativeBuildInputs = [ pkgs.zstd ]; }
    "zstd -3 -T0 -o $out ${raw}";


  derivedPayload =
    if host.install.script == null && host.variants.runtime.storage == "zfs"
    then throw ("install(${host.name}): a zfs target cannot be delivered as an image — a"
      + " pool is a kernel object with its own identity, not bytes on a disk (L2). State"
      + " install.script, the script that creates it.")
    else if host.install.script != null then {
      kind = "script";
      toplevel = host.variants.runtime.toplevel;
      storePaths = [ host.variants.runtime.toplevel ];
      inherit (host.install) script;
    } else {
      kind = "image";
      image = compressedImage runtimeEndpoints.image-raw.file;
      # Carried for the hand-over, and for nothing else: the act never reads it.
      toplevel = host.variants.runtime.toplevel;
    };

  payload =
    if host.install.payload != null then host.install.payload
    else derivedPayload;

  installerFor = { rootMode, faceFormat, isoLabel }:
    (install {
      inherit (host) name system;
      inherit payload;
      inherit (host.install) pool disks report encrypted completion;
      storage = host.variants.runtime.storage;
      machine = host.variants.runtime.machine;
      # No slot where the host carries no secrets: the installer builds no slot service and
      # writes no slot partition to the target.
      slotName = if slot == null then null else slot.name;
      slotFiles = map (f: f.target) host.secrets.files;
      inherit rootMode isoLabel;
      slotFace = if slot == null then null
                 else tools.slotFace { format = faceFormat; inherit (slot) name; };
    }).system;

  # Memoized per face as ATTRIBUTES, not calls: raw and qcow2 wrap the SAME installer, and
  # a repeated installerFor call is a second full eval-config of an identical system.
  installers = {
    disk = installerFor { rootMode = "disk"; faceFormat = "raw"; isoLabel = null; };
    memory = installerFor { rootMode = "memory"; faceFormat = "kexec"; isoLabel = null; };
    iso = installerFor { rootMode = "memory"; faceFormat = "iso"; isoLabel = isoInstallLabel; };
    # Memory-rooted like the netboot one, but its slot is the disk wrapper's partition —
    # read at boot, so the action may later wipe ANY disk, the boot medium included.
    rawMemory = installerFor { rootMode = "memory"; faceFormat = "raw"; isoLabel = null; };
  };

  # L6 mirrors L2: a squashfs store is written by the image, never by an install —
  # nixos-install populates a filesystem, and a squashfs is generated from one.
  guardL6 = f: v:
    if host.variants.runtime.storage == "squashfs"
    then throw ("unsupported (L6): a squashfs store is written by the image, never by an"
      + " install — deploy #image-${f} itself")
    else v;

  installEndpoints = lib.listToAttrs (map (f: {
    name = "image-${f}-install";
    value = guardL6 f (
      let
        installer =
          if f == "iso" then installers.iso
          else installers.${installerRootModeFor f};
      in
      imageFor f (installerShapeFor f) installer.rootMode installer "-install"
        (placementFor f) {
          # The installer's iso medium wears the -iso-install label, the same one its iso
          # face mounts by; derived once here like the runtime one.
          mediumLabel = if f == "iso" then isoInstallLabel else null;
        });
  }) formats);

  # The memory-rooted wrapper for the disk formats: the closure rides the initrd on the
  # ESP, so the booted installer holds no claim on any disk — the target is whatever the
  # host's layout names, the boot medium NOT excluded. The unmarked -install stays
  # disk-rooted: the medium carries the closure RAM-independently, and can only ever
  # install a different disk.
  inmemoryInstallEndpoints = lib.listToAttrs (map (f: {
    name = "image-${f}-install-inmemory";
    value = guardL6 f
      (imageFor f "squashfs" "memory" installers.rawMemory "-install-inmemory" "initrd" { });
  }) [ "raw" "qcow2" ]);

  personalizeFor = name: slot:
    if slot == null
    then {
      # A host that declares no embedded delivery gets a silent no-op, never a missing
      # endpoint — nothing may key off "the host has a bundle".
      run = tools.bashTool {
        name = "personalize-${name}";
        runtimeInputs = [ ];
        text = ''
          info "personalize ${name}: no embedded delivery declared — nothing to do"
        '';
      };
    }
    else personalize {
      inherit name slot;
      inherit (host.secrets) files;
    };
in

runtimeEndpoints // installEndpoints // inmemoryInstallEndpoints // {
  image-secrets-vfat = secrets {
    inherit (host) name;
    inherit (host.secrets) files;
    sidecarFormat = "vfat";
  };
  image-secrets-iso = secrets {
    inherit (host) name;
    inherit (host.secrets) files;
    sidecarFormat = "iso";
  };
  image-secrets-json = secrets {
    inherit (host) name;
    inherit (host.secrets) files;
    sidecarFormat = "json";
  };

  # Phase 2 has NO default target: the runner personalizes WHATEVER artifact it is handed
  # at run time, and this record only states what a slot IS on a disk artifact — the
  # partition the host's one slot declaration names. Every disk endpoint returns this same
  # record; nothing here picks a deliverable. The iso/kexec runners are the same phase 2
  # for the formats whose slot is a file / an initrd segment.
  image-personalize = personalizeFor host.name
    (let s = slotFor "raw";
     in if s == null then null
        else { destination = "partition"; name = s.name; fs = "vfat"; });
  image-personalize-iso = personalizeFor "${host.name}-iso" runtimeEndpoints.image-iso.slot;
  image-personalize-kexec = personalizeFor "${host.name}-kexec" runtimeEndpoints.image-kexec.slot;

  # Names for what a block already returned — lookups, never a second evaluation.
  closure = host.variants.runtime.toplevel;
  closure-live = runtimeEndpoints.image-iso.toplevel;
}
