{ pkgs, tools }:

let
  inherit (pkgs) lib;
  image = import ../../blocks/image/default.nix { inherit pkgs tools; };
  personalize = import ../../blocks/personalize/default.nix { inherit pkgs tools; };
  fixture = import ../../blocks/personalize/fixture.nix { inherit pkgs; };

  payload = {
    system = "x86_64-linux";
    toplevel = pkgs.writeText "toplevel" "what was packed";
    kernel = pkgs.writeText "bzImage" "not a kernel";
    initrd = pkgs.writeText "initrd" "not an initrd";
    espBinary = pkgs.writeText "systemd-boot.efi" "not a bootloader";
    kernelParams = [ "console=ttyS0" ];
    storePaths = [ pkgs.hello ];
  };

  slotted = image (payload // {
    name = "fixture"; format = "raw"; storeShape = "ext4"; rootMode = "disk";
    storePlacement = "partition";
    slot = { name = "secrets"; sizeMiB = 4; };
  });
  bare = image (payload // {
    name = "fixture"; format = "raw"; storeShape = "ext4"; rootMode = "disk";
    storePlacement = "partition";
  });
  slottedIso = image (payload // {
    name = "fixture"; format = "iso"; storeShape = "squashfs"; rootMode = "memory";
    storePlacement = null;
    # The composer supplies the iso medium's label; stand in for it the same way.
    mediumLabel = lib.toUpper (tools.ids.volumeId "fixture:iso");
    slot = { name = "secrets"; sizeMiB = 4; };
  });
  tree = image (payload // {
    name = "fixture"; format = "kexec"; storeShape = "squashfs"; rootMode = "memory";
    storePlacement = null;
    slot = { name = "secrets"; sizeMiB = 4; };
  });
  bareTree = image (payload // {
    name = "fixture"; format = "kexec"; storeShape = "squashfs"; rootMode = "memory";
    storePlacement = null;
  });

  # The block carries BYTES to a name and never looks at either: what a caller calls its
  # files, and what they are for, is the caller's business. The three content forms are
  # what a caller has — a file it points at, bytes it declared, a variable it exports.
  files = [ { target = "/sops.age"; content.file = "${fixture}/host.key"; } ];

  # The consumer validates what it RECEIVED: the descriptors come from image's out,
  # never restated by hand.
  runFor = args: lib.getExe (personalize ({ name = "fixture"; inherit files; } // args)).run;
  onPartition = runFor { slot = slotted.slot; };
  onFile = runFor { slot = slottedIso.slot; };
  onInitrd = runFor { slot = tree.slot; };
  everyForm = lib.getExe (personalize {
    name = "fixture";
    slot = slotted.slot;
    files = [
      { target = "/from-file"; content.file = "${fixture}/host.key"; }
      { target = "/from-text"; content.text = "declared in nix\n"; }
      { target = "/from-env"; content.env = "FIXTURE_SECRET"; }
    ];
  }).run;
  missingFile = runFor {
    slot = slotted.slot;
    files = [ { target = "/sops.age"; content.file = "/nowhere/at/all"; } ];
  };
  bothForms = builtins.tryEval (personalize {
    name = "fixture";
    slot = slotted.slot;
    files = [ { target = "/x"; content = { text = "a"; env = "B"; }; } ];
  }).run.drvPath;
in
assert lib.assertMsg (!bothForms.success)
  "a file declaring two content forms must be refused at eval";
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

    echo "== every content form lands, and env is read at RUN time, not eval =="
    install -m 0644 ${slotted.file} forms.img
    FIXTURE_SECRET='from the environment' ${everyForm} forms.img
    mcopy -i forms.img@@"$off" ::/from-file f1
    cmp f1 ${fixture}/host.key
    mcopy -i forms.img@@"$off" ::/from-text f2
    printf 'declared in nix\n' | cmp - f2
    mcopy -i forms.img@@"$off" ::/from-env f3
    printf 'from the environment' | cmp - f3

    echo "== refusal: an env form whose variable is unset, artifact untouched =="
    install -m 0644 ${slotted.file} unset.img
    ! ${everyForm} unset.img 2> refusal-env.log
    grep -q 'carries no FIXTURE_SECRET' refusal-env.log
    cmp unset.img ${slotted.file}

    echo "== refusal: a file form pointing nowhere, artifact untouched =="
    install -m 0644 ${slotted.file} missing.img
    ! ${missingFile} missing.img 2> refusal-file.log
    grep -q 'no such file to place' refusal-file.log
    cmp missing.img ${slotted.file}

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

    echo "== initrd-append: the RESERVED slot segment is required, then the file rides =="
    mkdir tree && cp ${tree.file}/* tree/ && chmod -R +w tree
    ${onInitrd} "$PWD/tree"

    echo "== refusal: a netboot tree whose image never declared a slot =="
    mkdir bare-tree && cp ${bareTree.file}/* bare-tree/ && chmod -R +w bare-tree
    ! ${onInitrd} "$PWD/bare-tree" 2> refusal3.log
    grep -q 'no slot segment' refusal3.log
    cmp bare-tree/initrd ${bareTree.file}/initrd

    touch $out
  ''
