# The composer: the ONE place that knows the host. It evaluates the variant the format asks
# for, extracts derivations and strings, picks the store shape, composes the slot, and hands
# each block only what its contract names. Blocks never see it and never see each other.
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
  # Format is the FIRST decision: a live format packs the memory-rooted variant, which the
  # composer evaluated — here it simply holds both. With real hosts this is the extendModules
  # step, and it happens before anything enters a block.
  variantFor = format:
    if builtins.elem format liveFormats then host.variants.live else host.variants.runtime;

  # The extraction: the one point where the pipe's carrier changes shape. Written out so it
  # stays visible — and small.
  extract = v: {
    inherit (v) toplevel kernel initrd kernelParams;
    storePaths = [ v.toplevel ];
  };

  # The store shape enters from above: the composer knows which format it is asking for.
  # image validates the pick — see the block.
  storeShapeFor = format: {
    iso = "squashfs";
    kexec = "cpio";
    ipxe = "cpio";
    raw = host.variants.runtime.storage;
    qcow2 = host.variants.runtime.storage;
  }.${format};

  # The extractor seam for the slot: today the slot is composed from the host's declared
  # deliveries; a storage layout that owns a shape would be READ here, not consulted by a block.
  slotFor = _format:
    if builtins.elem "embedded" host.secrets.delivery
    then { name = "secrets"; sizeMiB = 4; }
    else null;

  imageFor = format: system: nameSuffix:
    image ({
      name = "${host.name}-${format}${nameSuffix}";
      inherit format;
      inherit (host) system;
      storeShape = storeShapeFor format;
      slot = slotFor format;
    } // extract system);

  runtimeEndpoints = lib.listToAttrs (map (f: {
    name = "image-${f}";
    value = imageFor f (variantFor f) "";
  }) formats);

  # What gets installed is ALWAYS the host as it runs; the format only shapes the wrapper.
  # The installing OS is the block's own — live-shaped by construction.
  installer =
    (install {
      inherit (host) name;
      toplevel = host.variants.runtime.toplevel;
      closure = [ host.variants.runtime.toplevel ];
      inherit (host.install) prepare mount keyDestination;
    }).system;

  installEndpoints = lib.listToAttrs (map (f: {
    name = "image-${f}-install";
    value = imageFor f installer "-install";
  }) formats);
in

runtimeEndpoints // installEndpoints // {
  image-secrets-vfat = secrets {
    inherit (host) name;
    files = map (f: { inherit (f) target source; }) host.secrets.files;
    medium = "vfat";
  };
  image-secrets-iso = secrets {
    inherit (host) name;
    files = map (f: { inherit (f) target source; }) host.secrets.files;
    medium = "iso";
  };
  image-secrets-json = secrets {
    inherit (host) name;
    files = map (f: { inherit (f) target source; }) host.secrets.files;
    medium = "json";
  };

  image-personalize = personalize {
    inherit (host) name;
    slot = runtimeEndpoints.image-raw.slot;
    files = map (f: { inherit (f) target; source = f.runtimeSource; }) host.secrets.files;
  };

  # Names for what a block already returned — lookups, never a second evaluation.
  closure = host.variants.runtime.toplevel;
  closure-live = runtimeEndpoints.image-iso.toplevel;
}
