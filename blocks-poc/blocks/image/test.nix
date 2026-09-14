{ pkgs, tools }:

let
  inherit (pkgs) lib;
  image = import ./default.nix { inherit pkgs tools; };

  # Assembled BY HAND. No nixosSystem anywhere, no host anywhere.
  payload = {
    system = "x86_64-linux";
    toplevel = pkgs.writeText "toplevel" "not a system, but it is what was packed";
    kernel = pkgs.writeText "bzImage" "not a kernel, but it is a file";
    initrd = pkgs.writeText "initrd" "not an initrd either";
    kernelParams = [ "console=ttyS0" "root=LABEL=nixos" ];
    storePaths = [ pkgs.hello ];
  };

  # THE MATRIX: every legal (format, store shape, slot) combination, each built and probed.
  # The legal map is restated here ON PURPOSE — a test that derives its expectations from
  # the block under test agrees with itself.
  legal = {
    raw = [ "ext4" "squashfs" ];
    qcow2 = [ "ext4" "squashfs" ];
    iso = [ "squashfs" ];
    kexec = [ "cpio" ];
    ipxe = [ "cpio" ];
  };
  formats = lib.attrNames legal;
  slots = [ null { name = "secrets"; sizeMiB = 4; } ];

  caseName = f: s: slot:
    "fixture-${f}-${s}" + lib.optionalString (slot != null) "-slot";
  build = f: s: slot: image (payload // {
    name = caseName f s slot;
    format = f;
    storeShape = s;
    inherit slot;
  });
  cases = lib.concatMap (f:
    lib.concatMap (s: map (slot: rec {
      format = f; shape = s; inherit slot;
      built = build f s slot;
      slotted = slot != null;
    }) slots) legal.${f}) formats;

  # Same builder, same inputs, a different derivation — so nix really builds it a second
  # time. Two builds of ONE derivation are the same store path, which is why a
  # non-deterministic builder is invisible to nix and why this has to be forced.
  again = d: d.overrideAttrs (_: { determinismProbe = "2"; });

  other = image (payload // { name = "other"; format = "raw"; storeShape = "ext4"; });
  otherIso = image (payload // { name = "other"; format = "iso"; storeShape = "squashfs"; });

  # A wrong composition fails at eval, in image — not at boot on the machine. The set is
  # the COMPLEMENT of the legal map: every shape a format does not take.
  allShapes = [ "ext4" "squashfs" "cpio" ];
  refused = f: s:
    !(builtins.tryEval (image (payload // {
      name = "bad"; format = f; storeShape = s;
    })).file.outPath).success;
  refusals = lib.concatMap (f:
    map (s: { inherit f s; ok = refused f s; })
      (lib.subtractLists legal.${f} allShapes)) formats;

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
        format = "raw"; storeShape = c.shape; slot = c.slot;
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
      debugfs -R "ls /nix/store" part.img | tr ' ' '\n' | grep -q hello
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
    echo "== ${c.built.file.name}: one payload, both descriptors, store cpio appended =="
    [ -x ${c.built.file}/kexec.sh ]
    grep -q 'console=ttyS0' ${c.built.file}/kexec.sh
    grep -q 'console=ttyS0' ${c.built.file}/boot.ipxe
    n="$(stat -c%s ${payload.initrd})"
    cmp -n "$n" ${c.built.file}/initrd ${payload.initrd}
    tail -c +$(( n + 1 )) ${c.built.file}/initrd \
      | cpio -t --quiet | grep -q 'nix/store/nix-path-registration'
  '';

  checksFor = c:
    if c.format == "raw" || c.format == "qcow2" then diskChecks c
    else if c.format == "iso" then isoChecks c
    else netbootChecks c;

  determinism = c:
    if c.format == "kexec" || c.format == "ipxe"
    then "diff -r ${c.built.file} ${again c.built.file}\n"
    else "cmp ${c.built.file} ${again c.built.file}\n";

  # kexec and ipxe are ONE payload: for every (shape, slot) the two trees must be equal in
  # CONTENT (their store paths differ, their bytes may not).
  pairChecks = lib.concatMap (slot: [
    "diff -r ${(build "kexec" "cpio" slot).file} ${(build "ipxe" "cpio" slot).file}\n"
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

    echo "== the caller never said BOOTX64.EFI — the block knew =="
    esp_off="$(jq -r '.[] | select(.label=="ESP") | .startByte' ${fixtureRaw.layout})"
    mdir -i ${fixtureRaw.file}@@"$esp_off" -/ ::/EFI/BOOT | grep -q BOOTX64
    mcopy -i ${fixtureRaw.file}@@"$esp_off" ::/loader/entries/nixos.conf - \
      | grep -q 'options console=ttyS0 root=LABEL=nixos'

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
