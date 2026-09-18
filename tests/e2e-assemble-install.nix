# The CLOSURE delivery, end to end: the installer carries the pieces its disk is made of
# and lays that disk out on the target — the ESP written as built, the store filesystem
# created on a partition sized to the disk actually found, the slot formatted empty and
# filled afterwards. Then it hands over with kexec to what it just wrote.
#
# What this proves that the image delivery cannot: the same host, the same artifact pieces,
# but the store partition takes the REST OF THE DISK. The target here is far larger than
# the image would have been, and the assembled store is sized to it — which is the whole
# reason to build on the machine rather than carry a finished disk.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.assemble-install;
  fixture = import ../blocks/personalize/fixture.nix { inherit pkgs; };
in
{
  witnesses = [ "assemble-install.image-kexec-install"
                "assemble-install.image-personalize-kexec" ];
  check = pkgs.runCommand "e2e-assemble-install"
  {
    nativeBuildInputs = [ pkgs.qemu pkgs.age pkgs.mtools pkgs.dosfstools pkgs.gptfdisk
                          pkgs.gawk pkgs.e2fsprogs ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail
    mkdir tree
    cp ${e.image-kexec-install.file}/* tree/
    chmod -R +w tree
    ${lib.getExe e.image-personalize-kexec.run} "$PWD/tree"

    cmdline="$(sed -n "s/^.*--command-line='\(.*\)'$/\1/p" tree/kexec.sh)"
    [ -n "$cmdline" ] || { echo "no command line in kexec.sh" >&2; exit 1; }

    # Deliberately much larger than this host's image: the store must grow into it.
    truncate -s 12G target.img
    truncate -s 16M result.img; mkfs.fat -n E2EOUT result.img > /dev/null

    echo "== the installer lays the disk out and hands over =="
    sc=0
    timeout 1800 qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 2 \
      -kernel tree/kernel -initrd tree/initrd -append "$cmdline" \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=eout,format=raw,file=result.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:install.log -display none -no-reboot || sc=$?
    echo "install qemu exited $sc" >&2
    mcopy -i result.img ::/log result 2>/dev/null || touch result
    echo "=== result:" >&2; cat result >&2
    grep -q "installer: slot taken over" result || {
      echo "=== installer console:" >&2; tail -n 60 install.log >&2; exit 1
    }
    grep -q "INSTALL-OK e2e-assemble-install" result || {
      echo "=== installer console:" >&2; tail -n 60 install.log >&2; exit 1
    }
    grep -q "HANDOVER e2e-assemble-install" result
    grep -q "E2E-BOOT-OK e2e-assemble-install" result
    grep -q "E2E-DB-OK" result
    pub="$(age-keygen -y ${fixture}/host.key)"
    grep -q "E2E-KEY $pub" result

    echo "== the store partition took the disk it found, not the size of an image =="
    store_num="$(sgdisk -p target.img | awk '$NF == "nixos" { print $1 }')"
    [ -n "$store_num" ]
    store_sectors="$(sgdisk -i "$store_num" target.img \
      | awk '/^Partition size/ { print $3 }')"
    store_gib=$(( store_sectors * 512 / 1073741824 ))
    echo "store partition: $store_gib GiB of a 12 GiB disk" >&2
    # The image of this same host is ~1.4 GiB; anything near that means the disk was not
    # sized on the machine.
    [ "$store_gib" -ge 9 ]

    echo "== and it carries the artifact's own identity, not one made up on the machine =="
    # The store's uuid is derived from this host's name, the same way the image endpoint
    # derives it — so a match says the disk was assembled from that artifact's pieces.
    # Read straight out of the ext4 superblock (1024 + 0x68), which needs no tool to
    # accept a partial image first.
    store_start="$(sgdisk -i "$store_num" target.img | awk '/^First sector/ { print $3 }')"
    raw="$(dd if=target.img bs=1 skip=$(( store_start * 512 + 1128 )) count=16 status=none \
      | od -An -tx1 | tr -d ' \n')"
    uuid="''${raw:0:8}-''${raw:8:4}-''${raw:12:4}-''${raw:16:4}-''${raw:20:12}"
    echo "store uuid on disk: $uuid" >&2
    [ "$uuid" = ${e.image-raw.parts.storeUuid} ]

    touch "$out"
  ''
  ;
}
