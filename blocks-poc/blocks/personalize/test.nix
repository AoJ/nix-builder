{ pkgs, tools }:

let
  inherit (pkgs) lib;
  image = import ../image/default.nix { inherit pkgs tools; };
  personalize = import ./default.nix { inherit pkgs tools; };
  fixture = import ./fixture.nix { inherit pkgs; };

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

  # The throwaway key IS the planted file, so the whole chain is real: the runner derives
  # its public half and matches it against the bundle's recipients before anything lands.
  files = [ { target = "/sops.age"; source = "${fixture}/host.key"; } ];

  # The consumer validates what it RECEIVED: the descriptors come from image's out,
  # never restated by hand.
  runFor = args: lib.getExe (personalize ({ name = "fixture"; inherit files; } // args)).run;
  onPartition = runFor {
    slot = slotted.slot;
    recipientCheck = { bundle = "${fixture}/bundle.yaml"; keyTarget = "/sops.age"; };
  };
  onFile = runFor {
    slot = slottedIso.slot;
    recipientCheck = { bundle = "${fixture}/bundle.json"; keyTarget = "/sops.age"; };
  };
  onInitrd = runFor { slot = { medium = "initrd-append"; }; };
  foreignKey = runFor {
    slot = slotted.slot;
    recipientCheck = { bundle = "${fixture}/bundle-foreign.yaml"; keyTarget = "/sops.age"; };
  };
  unreadable = runFor {
    slot = slotted.slot;
    recipientCheck = { bundle = "${fixture}/garbage"; keyTarget = "/sops.age"; };
  };
in
pkgs.runCommand "test-personalize"
  { nativeBuildInputs = [
      pkgs.mtools pkgs.gptfdisk pkgs.xorriso pkgs.cpio pkgs.coreutils pkgs.jq
    ];
  }
  ''
    set -euo pipefail

    echo "== partition slot, YAML bundle: the key belongs, lands, and reads back =="
    install -m 0644 ${slotted.file} work.img
    ${onPartition} work.img
    off="$(jq -r '.[] | select(.label=="secrets") | .startByte' ${slotted.layout})"
    mcopy -i work.img@@"$off" ::/sops.age got
    cmp got ${fixture}/host.key

    echo "== phase one stayed secret-free: the pristine artifact does not hold the key =="
    ! mdir -b -i ${slotted.file}@@"$off" :: | grep -q sops.age

    echo "== refusal: another host's bundle — the key is NOT planted =="
    install -m 0644 ${slotted.file} foreign.img
    ! ${foreignKey} foreign.img 2> refusal-key.log
    grep -q 'not a recipient' refusal-key.log
    cmp foreign.img ${slotted.file}

    echo "== refusal: a bundle the check cannot read is NAMED, not skipped =="
    install -m 0644 ${slotted.file} unread.img
    ! ${unreadable} unread.img 2> refusal-read.log
    grep -q 'cannot read recipients' refusal-read.log
    cmp unread.img ${slotted.file}

    echo "== refusal: no slot in the artifact — and NOTHING was written =="
    install -m 0644 ${bare.file} bare.img
    ! ${onPartition} bare.img 2> refusal.log
    grep -q 'no partition named secrets' refusal.log
    cmp bare.img ${bare.file}

    echo "== refusal: the slot is declared but holds no filesystem =="
    truncate -s 8M hole.img
    sgdisk -Z hole.img > /dev/null
    sgdisk -n 1:2048:+4M -c 1:secrets hole.img > /dev/null
    cp hole.img hole-pristine.img
    ! ${onPartition} hole.img 2> refusal2.log
    grep -q 'holds no filesystem' refusal2.log
    cmp hole.img hole-pristine.img

    echo "== file slot in an iso, JSON bundle: found by report_lba, key lands =="
    install -m 0644 ${slottedIso.file} work.iso
    ${onFile} work.iso

    echo "== initrd-append: no check declared, the appended segment carries the file =="
    mkdir tree && cp ${tree.file}/* tree/ && chmod -R +w tree
    ${onInitrd} "$PWD/tree"

    touch $out
  ''
