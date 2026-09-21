{ pkgs, tools }:

let
  inherit (pkgs) lib;
  image = import ../../blocks/image/default.nix { inherit pkgs tools; };

  # Assembled BY HAND. No nixosSystem anywhere, no host anywhere.
  payload = {
    system = "x86_64-linux";
    toplevel = pkgs.writeText "toplevel" "not a system, but it is what was packed";
    kernel = pkgs.writeText "bzImage" "not a kernel, but it is a file";
    initrd = pkgs.writeText "initrd" "not an initrd either";
    espBinary = pkgs.writeText "systemd-boot.efi" "not a bootloader, but it is a file";
    kernelParams = [ "console=ttyS0" "root=LABEL=nixos" ];
    storePaths = [ pkgs.hello ];
  };

  rootModeFor = f: if builtins.elem f [ "iso" "kexec" "ipxe" ] then "memory" else "disk";
  placementFor = f: if f == "raw" || f == "qcow2" then "partition" else null;

  # THE MATRIX: every legal (format, store shape, slot, placement) combination, each built
  # and probed. The legal map is restated here ON PURPOSE — a test that derives its
  # expectations from the block under test agrees with itself.
  legal = {
    raw = [ "ext4" "squashfs" ];
    qcow2 = [ "ext4" "squashfs" ];
    iso = [ "squashfs" ];
    kexec = [ "squashfs" ];
    ipxe = [ "squashfs" ];
  };
  formats = lib.attrNames legal;
  slots = [ null { name = "secrets"; sizeMiB = 4; } ];

  caseName = f: s: slot:
    "fixture-${f}-${s}" + lib.optionalString (slot != null) "-slot";
  # The composer supplies the iso medium's label, derived from the artifact NAME through the
  # ids tool; stand in for it here the same way, so two differently-named fixtures get two
  # ids (no shared constant), exactly as the composer would.
  mediumLabelFor = f: name:
    if f == "iso" then lib.toUpper (tools.ids.volumeId "${name}:iso") else null;
  build = f: s: slot:
    let name = caseName f s slot;
    in image (payload // {
      inherit name;
      format = f;
      storeShape = s;
      rootMode = rootModeFor f;
      storePlacement = placementFor f;
      mediumLabel = mediumLabelFor f name;
      inherit slot;
    });
  buildInitrd = f: slot:
    let name = caseName f "squashfs" slot + "-initrd";
    in image (payload // {
      inherit name;
      format = f;
      storeShape = "squashfs";
      rootMode = "memory";
      storePlacement = "initrd";
      mediumLabel = mediumLabelFor f name;
      inherit slot;
    });
  cases = lib.concatMap (f:
    lib.concatMap (s: map (slot: rec {
      format = f; shape = s; inherit slot;
      placement = placementFor f;
      built = build f s slot;
      slotted = slot != null;
    }) slots) legal.${f}) formats
  # The initrd-carried disks: squashfs, memory-rooted, both disk envelopes, slot or none.
  ++ lib.concatMap (f: map (slot: rec {
      format = f; shape = "squashfs"; inherit slot;
      placement = "initrd";
      built = buildInitrd f slot;
      slotted = slot != null;
    }) slots) [ "raw" "qcow2" ];

  # Same builder, same inputs, a different derivation — so nix really builds it a second
  # time. Two builds of ONE derivation are the same store path, which is why a
  # non-deterministic builder is invisible to nix and why this has to be forced.
  again = d: d.overrideAttrs (_: { determinismProbe = "2"; });

  other = image (payload // {
    name = "other"; format = "raw"; storeShape = "ext4"; rootMode = "disk";
    storePlacement = "partition";
  });
  otherIso = image (payload // {
    name = "other"; format = "iso"; storeShape = "squashfs"; rootMode = "memory";
    storePlacement = null; mediumLabel = mediumLabelFor "iso" "other";
  });

  # An aarch64 artifact assembles NATIVELY: the tools are the runner's, the bootloader is
  # the caller's — nothing here executes target code, which is what keeps the arm builder
  # out of the image path.
  asAarch64 = image (payload // {
    name = "fixture-aarch64"; system = "aarch64-linux";
    format = "raw"; storeShape = "ext4"; rootMode = "disk";
    storePlacement = "partition";
  });

  # A wrong composition fails at eval, in image — not at boot on the machine. The sets are
  # the COMPLEMENTS of the legal maps: every shape a format does not take, every root mode
  # it cannot boot, and every placement the contract rules out.
  allShapes = [ "ext4" "squashfs" ];
  refused = f: s: r: p:
    !(builtins.tryEval (image (payload // {
      name = "bad"; format = f; storeShape = s; rootMode = r; storePlacement = p;
    })).file.outPath).success;
  refusals =
    lib.concatMap (f:
      map (s: { inherit f s; ok = refused f s (rootModeFor f) (placementFor f); })
        (lib.subtractLists legal.${f} allShapes)) formats
    ++ map (f: { inherit f; r = "disk";
                 ok = refused f (builtins.head legal.${f}) "disk" (placementFor f); })
      [ "iso" "kexec" "ipxe" ]
    # The placement rules: a disk format must state one, the fixed formats must not, and
    # an initrd-carried store is squashfs and memory-rooted — each denial by itself.
    ++ [
      { why = "raw without a placement"; ok = refused "raw" "ext4" "disk" null; }
      { why = "qcow2 without a placement"; ok = refused "qcow2" "ext4" "disk" null; }
      { why = "iso told a placement"; ok = refused "iso" "squashfs" "memory" "partition"; }
      { why = "kexec told a placement"; ok = refused "kexec" "squashfs" "memory" "initrd"; }
      { why = "initrd store, ext4"; ok = refused "raw" "ext4" "memory" "initrd"; }
      { why = "initrd store, disk-rooted"; ok = refused "raw" "squashfs" "disk" "initrd"; }
    ];

  # Per-format probes. Each reads names and offsets OUT of the artifact (or its emitted
  # layout), never restating them.
  diskChecks = c: ''
    echo "== ${c.built.file.name}: GPT table, store partition is ${c.shape}, slot ${
      if c.slotted then "reserved+formatted+EMPTY" else "absent"} =="
    img=${if c.format == "qcow2" then "converted.img" else c.built.file}
    ${lib.optionalString (c.format == "qcow2") ''
      qemu-img convert -f qcow2 -O raw ${c.built.file} converted.img
      cmp converted.img ${(image (payload // {
        name = caseName "qcow2" c.shape c.slot;
        format = "raw"; storeShape = c.shape; rootMode = "disk"; slot = c.slot;
        storePlacement = "partition";
      })).file}
    ''}
    sgdisk -p "$img" | grep -q ESP
    sgdisk -p "$img" | grep -q nixos
    root_off="$(jq -r '.[] | select(.label=="nixos") | .startByte' ${c.built.layout})"
    root_len="$(jq -r '.[] | select(.label=="nixos") | .sizeByte' ${c.built.layout})"
    dd if="$img" of=part.img bs=1M skip=$(( root_off / 1048576 )) \
       count=$(( (root_len + 1048575) / 1048576 )) status=none
    ${if c.shape == "ext4" then ''
      dumpe2fs -h part.img > /dev/null 2>&1
      debugfs -R "ls /nix/store" part.img | tr ' ' '\n' | grep hello > /dev/null
    '' else ''
      unsquashfs -l part.img | grep -q hello
      unsquashfs -l part.img | grep -q nix-path-registration
    ''}
    ${if c.slotted then ''
      slot_off="$(jq -r '.[] | select(.label=="secrets") | .startByte' ${c.built.layout})"
      [ "$(mdir -b -i "$img"@@"$slot_off" :: | wc -l)" = 0 ]
    '' else ''
      ! sgdisk -p "$img" | grep -q secrets
    ''}
  '';

  isoChecks = c: ''
    echo "== ${c.built.file.name}: El Torito boots the ESP image, store and slot inside =="
    xorriso -indev ${c.built.file} -report_el_torito plain 2>/dev/null | grep -q 'boot/efi.img'
    efi_lba="$(xorriso -indev ${c.built.file} -find /boot/efi.img -exec report_lba -- 2>/dev/null \
      | awk -F, '/^File data lba/ { gsub(/ /,"",$2); print $2 }')"
    mdir -i ${c.built.file}@@$(( efi_lba * 2048 )) -/ ::/EFI/BOOT | grep -q BOOTX64
    mcopy -i ${c.built.file}@@$(( efi_lba * 2048 )) ::/loader/entries/nixos.conf - \
      | grep -q 'options console=ttyS0 root=LABEL=nixos'
    xorriso -indev ${c.built.file} -find /nix-store.squashfs 2>/dev/null | grep -q squashfs
    ${if c.slotted then ''
      xorriso -indev ${c.built.file} -find ${lib.escapeShellArg c.built.slot.path} \
        2>/dev/null | grep -q secrets
    '' else ''
      ! xorriso -indev ${c.built.file} -find /boot/secrets.img 2>/dev/null | grep -q secrets
    ''}
  '';

  netbootChecks = c: ''
    echo "== ${c.built.file.name}: one payload, both descriptors, squashfs store appended =="
    [ -x ${c.built.file}/kexec.sh ]
    grep -q 'console=ttyS0' ${c.built.file}/kexec.sh
    grep -q 'console=ttyS0' ${c.built.file}/boot.ipxe
    n="$(stat -c%s ${payload.initrd})"
    cmp -n "$n" ${c.built.file}/initrd ${payload.initrd}
    tail -c +$(( n + 1 )) ${c.built.file}/initrd \
      | cpio -t --quiet | grep -qx 'nix-store.squashfs'
    rm -rf seg && mkdir seg
    tail -c +$(( n + 1 )) ${c.built.file}/initrd \
      | (cd seg && cpio -i --quiet 2>/dev/null)
    unsquashfs -l seg/nix-store.squashfs | grep -q nix-path-registration
    unsquashfs -l seg/nix-store.squashfs | grep -q hello
    ${if c.slotted then ''
      grep -aqF -- '.slot-secrets' ${c.built.file}/initrd
    '' else ''
      ! grep -aqF -- '.slot-' ${c.built.file}/initrd
    ''}
  '';

  # The initrd-carried disk: nothing on it but the ESP (and the slot) — the store rides
  # the initrd behind the bootloader, and the slot is the PARTITION, never a marker
  # segment. Probed from the artifact: the ESP's initrd is the base initrd plus the
  # squashfs cpio segment, extracted and listed.
  initrdDiskChecks = c: ''
    echo "== ${c.built.file.name}: ESP-only GPT, store in the initrd, slot ${
      if c.slotted then "a partition" else "absent"} =="
    img=${if c.format == "qcow2" then "converted.img" else c.built.file}
    ${lib.optionalString (c.format == "qcow2") ''
      qemu-img convert -f qcow2 -O raw ${c.built.file} converted.img
      cmp converted.img ${(image (payload // {
        name = caseName "qcow2" "squashfs" c.slot + "-initrd";
        format = "raw"; storeShape = "squashfs"; rootMode = "memory";
        storePlacement = "initrd"; slot = c.slot;
      })).file}
    ''}
    sgdisk -p "$img" | grep -q ESP
    ! sgdisk -p "$img" | grep -qw nixos
    esp_off="$(jq -r '.[] | select(.label=="ESP") | .startByte' ${c.built.layout})"
    mdir -i "$img"@@"$esp_off" -/ :: | grep -q nixos-initrd
    mcopy -i "$img"@@"$esp_off" ::/nixos-initrd carried-initrd
    n="$(stat -c%s ${payload.initrd})"
    cmp -n "$n" carried-initrd ${payload.initrd}
    tail -c +$(( n + 1 )) carried-initrd | cpio -t --quiet | grep -qx 'nix-store.squashfs'
    rm -rf seg && mkdir seg
    tail -c +$(( n + 1 )) carried-initrd | (cd seg && cpio -i --quiet 2>/dev/null)
    unsquashfs -l seg/nix-store.squashfs | grep -q hello
    ! grep -aqF -- '.slot-' carried-initrd
    ${if c.slotted then ''
      slot_off="$(jq -r '.[] | select(.label=="secrets") | .startByte' ${c.built.layout})"
      [ "$(mdir -b -i "$img"@@"$slot_off" :: | wc -l)" = 0 ]
    '' else ''
      ! sgdisk -p "$img" | grep -q secrets
    ''}
  '';

  checksFor = c:
    if c.placement == "initrd" then initrdDiskChecks c
    else if c.format == "raw" || c.format == "qcow2" then diskChecks c
    else if c.format == "iso" then isoChecks c
    else netbootChecks c;

  determinism = c:
    if c.format == "kexec" || c.format == "ipxe"
    then "diff -r ${c.built.file} ${again c.built.file}\n"
    else "cmp ${c.built.file} ${again c.built.file}\n";

  # kexec and ipxe are ONE payload: for every (shape, slot) the two trees must be equal in
  # CONTENT (their store paths differ, their bytes may not).
  pairChecks = lib.concatMap (slot: [
    "diff -r ${(build "kexec" "squashfs" slot).file} ${(build "ipxe" "squashfs" slot).file}\n"
  ]) slots;

  fixtureRaw = build "raw" "ext4" null;
in

assert lib.assertMsg (lib.all (c: c.built.toplevel == payload.toplevel) cases)
  "every output must carry the toplevel that was packed";
assert lib.assertMsg (lib.all (r: r.ok) refusals)
  "an illegal (format, store shape) composition must fail at eval: ${builtins.toJSON refusals}";
assert lib.assertMsg (lib.all (c: !c.slotted -> c.built.slot == null) cases)
  "no slot asked for, none declared";

pkgs.runCommand "test-image"
  { nativeBuildInputs = [
      pkgs.gptfdisk pkgs.mtools pkgs.e2fsprogs pkgs.squashfsTools pkgs.jq
      pkgs.qemu-utils pkgs.xorriso pkgs.cpio pkgs.coreutils pkgs.diffutils pkgs.gawk
    ];
  }
  ''
    set -euo pipefail

    ${lib.concatMapStrings checksFor cases}

    echo "== the caller never said BOOTX64.EFI — the block knew, per architecture =="
    esp_off="$(jq -r '.[] | select(.label=="ESP") | .startByte' ${fixtureRaw.layout})"
    mdir -i ${fixtureRaw.file}@@"$esp_off" -/ ::/EFI/BOOT | grep -q BOOTX64
    mcopy -i ${fixtureRaw.file}@@"$esp_off" ::/loader/entries/nixos.conf - \
      | grep -q 'options console=ttyS0 root=LABEL=nixos'
    aa_off="$(jq -r '.[] | select(.label=="ESP") | .startByte' ${asAarch64.layout})"
    mdir -i ${asAarch64.file}@@"$aa_off" -/ ::/EFI/BOOT | grep -q BOOTAA64
    mcopy -i ${asAarch64.file}@@"$aa_off" ::/EFI/BOOT/BOOTAA64.EFI - | cmp - ${payload.espBinary}

    echo "== built twice, byte for byte the same — every case =="
    ${lib.concatMapStrings determinism cases}

    echo "== kexec and ipxe of one composition are the same content =="
    ${lib.concatStrings pairChecks}

    echo "== two names, two identities: no shared constant =="
    mine="$(sgdisk -p ${fixtureRaw.file} | awk '/Disk identifier/ { print $NF }')"
    theirs="$(sgdisk -p ${other.file} | awk '/Disk identifier/ { print $NF }')"
    [ -n "$mine" ] && [ "$mine" != "$theirs" ]
    iso_mine="$(xorriso -indev ${(build "iso" "squashfs" null).file} -pvd_info 2>/dev/null \
      | awk '/Volume Id/ { print $4 }')"
    iso_other="$(xorriso -indev ${otherIso.file} -pvd_info 2>/dev/null \
      | awk '/Volume Id/ { print $4 }')"
    [ -n "$iso_mine" ] && [ "$iso_mine" != "$iso_other" ]

    touch $out
  ''
