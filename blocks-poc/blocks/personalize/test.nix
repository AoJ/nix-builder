{ pkgs, tools }:

let
  inherit (pkgs) lib;
  image = import ../image/default.nix { inherit pkgs tools; };
  personalize = import ./default.nix { inherit pkgs tools; };

  payload = {
    system = "x86_64-linux";
    toplevel = pkgs.writeText "toplevel" "what was packed";
    kernel = pkgs.writeText "bzImage" "not a kernel";
    initrd = pkgs.writeText "initrd" "not an initrd";
    kernelParams = [ "console=ttyS0" ];
    storePaths = [ pkgs.hello ];
  };

  slotted = image (payload // {
    name = "fixture"; format = "raw"; storeShape = "ext4";
    slot = { name = "secrets"; sizeMiB = 4; };
  });
  bare = image (payload // { name = "fixture"; format = "raw"; storeShape = "ext4"; });
  slottedIso = image (payload // {
    name = "fixture"; format = "iso"; storeShape = "squashfs";
    slot = { name = "secrets"; sizeMiB = 4; };
  });
  tree = image (payload // { name = "fixture"; format = "kexec"; storeShape = "cpio"; });

  # A fixture key, so a test can hold what it is testing. Nobody personalizes a real
  # host's artifact here.
  fixture = pkgs.writeText "age-key-fixture" "AGE-SECRET-KEY-FIXTURE";
  files = [ { target = "/sops.age"; source = "${fixture}"; } ];

  # The consumer validates what it RECEIVED: the descriptors come from image's out,
  # never restated by hand.
  onPartition = personalize { name = "fixture"; slot = slotted.slot; inherit files; };
  onFile = personalize { name = "fixture"; slot = slottedIso.slot; inherit files; };
  onInitrd = personalize {
    name = "fixture";
    slot = { medium = "initrd-append"; };
    inherit files;
  };
in
pkgs.runCommand "test-personalize"
  { nativeBuildInputs = [ pkgs.mtools pkgs.gptfdisk pkgs.xorriso pkgs.cpio pkgs.coreutils pkgs.jq ]; }
  ''
    set -euo pipefail

    echo "== partition slot: the key lands, and reads back identical =="
    install -m 0644 ${slotted.file} work.img
    ${lib.getExe onPartition.run} work.img
    off="$(jq -r '.[] | select(.label=="secrets") | .startByte' ${slotted.layout})"
    mcopy -i work.img@@"$off" ::/sops.age got
    cmp got ${fixture}

    echo "== phase one stayed secret-free: the pristine artifact does not hold the key =="
    ! mdir -b -i ${slotted.file}@@"$off" :: | grep -q sops.age

    echo "== refusal: no slot in the artifact — and NOTHING was written =="
    install -m 0644 ${bare.file} bare.img
    ! ${lib.getExe onPartition.run} bare.img 2> refusal.log
    grep -q 'no partition named secrets' refusal.log
    cmp bare.img ${bare.file}

    echo "== refusal: the slot is declared but holds no filesystem =="
    truncate -s 8M hole.img
    sgdisk -Z hole.img > /dev/null
    sgdisk -n 1:2048:+4M -c 1:secrets hole.img > /dev/null
    cp hole.img hole-pristine.img
    ! ${lib.getExe onPartition.run} hole.img 2> refusal2.log
    grep -q 'holds no filesystem' refusal2.log
    cmp hole.img hole-pristine.img

    echo "== file slot in an iso: found by report_lba out of the artifact, key lands =="
    install -m 0644 ${slottedIso.file} work.iso
    ${lib.getExe onFile.run} work.iso

    echo "== initrd-append: the appended segment carries the file =="
    mkdir tree && cp ${tree.file}/* tree/ && chmod -R +w tree
    ${lib.getExe onInitrd.run} "$PWD/tree"

    touch $out
  ''
