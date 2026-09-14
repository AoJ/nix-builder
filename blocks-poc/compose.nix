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

host:

let
  # The label is the one constant spanning eval and artifact: both sides derive it from
  # the same name through the same ids tool, and the e2e boot tests the agreement.
  isoLabel = lib.toUpper (tools.ids.volumeId "${host.name}-iso:iso");
  variantFor = format:
    if format == "iso" && host.variants ? liveIso then host.variants.liveIso isoLabel
    else if builtins.elem format liveFormats then host.variants.live
    else host.variants.runtime;

  extract = v: {
    inherit (v) toplevel kernel initrd kernelParams espBinary rootMode;
    storePaths = [ v.toplevel ];
  };

  # L2 makes one combination a NAMED hole: a zfs pool is created by the install, never by
  # the image.
  diskShape =
    if host.variants.runtime.storage == "zfs"
    then throw ("unsupported (L2): a zfs pool is created by the install, never by the image"
      + " — use #image-<format>-install")
    else host.variants.runtime.storage;
  storeShapeFor = format: {
    iso = "squashfs";
    kexec = "cpio";
    ipxe = "cpio";
    raw = diskShape;
    qcow2 = diskShape;
  }.${format};

  # The installer is an OS of its own; its store and root mode are the WRAPPER's, so the
  # target's storage never shapes them and the L2 hole does not exist on the -install half.
  # The memory-rooted installer does not exist yet: install refuses it by name.
  installerShapeFor = format: {
    iso = "squashfs";
    kexec = "cpio";
    ipxe = "cpio";
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
    if builtins.elem "embedded" delivery
    then { name = "secrets"; sizeMiB = 4; }
    else null;

  imageFor = format: shape: rootMode: system: nameSuffix:
    image ({
      name = "${host.name}-${format}${nameSuffix}";
      inherit format;
      inherit (host) system;
      storeShape = shape;
      slot = slotFor format;
    } // extract system // { inherit rootMode; });

  runtimeEndpoints = lib.listToAttrs (map (f: rec {
    name = "image-${f}";
    value =
      let v = variantFor f;
      in imageFor f (storeShapeFor f) v.rootMode v "";
  }) formats);

  # What gets installed is ALWAYS the host as it runs; the format only shapes the wrapper.
  installerFor = rootMode:
    (install {
      inherit (host) name system;
      toplevel = host.variants.runtime.toplevel;
      closure = [ host.variants.runtime.toplevel ];
      inherit (host.install) prepare mount pool keyDestination;
      inherit rootMode;
    }).system;

  installEndpoints = lib.listToAttrs (map (f: {
    name = "image-${f}-install";
    value =
      let installer = installerFor (installerRootModeFor f);
      in imageFor f (installerShapeFor f) installer.rootMode installer "-install";
  }) formats);

  sidecarFiles = map (f: { inherit (f) target; source = f.runtimeSource; }) host.secrets.files;

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
      files = sidecarFiles;
      recipientCheck =
        if host.secrets ? bundle
        then { inherit (host.secrets) bundle keyTarget; }
        else null;
    };
in

runtimeEndpoints // installEndpoints // {
  image-secrets-vfat = secrets {
    inherit (host) name;
    files = sidecarFiles;
    medium = "vfat";
  };
  image-secrets-iso = secrets {
    inherit (host) name;
    files = sidecarFiles;
    medium = "iso";
  };
  image-secrets-json = secrets {
    inherit (host) name;
    files = sidecarFiles;
    medium = "json";
  };

  # Bound to the host's DELIVERABLE: for a zfs host the -install artifact (L2 — the runtime
  # disk endpoints are the hole), for everyone else the runtime image; the iso runner is
  # the same phase 2 against the iso artifact's slot FILE.
  image-personalize = personalizeFor host.name
    (if host.variants.runtime.storage == "zfs"
     then installEndpoints.image-raw-install.slot
     else runtimeEndpoints.image-raw.slot);
  image-personalize-iso = personalizeFor "${host.name}-iso" runtimeEndpoints.image-iso.slot;

  # Names for what a block already returned — lookups, never a second evaluation.
  closure = host.variants.runtime.toplevel;
  closure-live = runtimeEndpoints.image-iso.toplevel;
}
