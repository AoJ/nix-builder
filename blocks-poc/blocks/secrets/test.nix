{ pkgs, tools }:

let
  inherit (pkgs) lib;
  secrets = import ./default.nix { inherit pkgs tools; };

  fixture = pkgs.writeText "age-key-fixture" "AGE-SECRET-KEY-FIXTURE";
  files = [ { target = "/sops.age"; source = "${fixture}"; } ];

  runFor = args: lib.getExe (secrets ({ inherit files; } // args)).run;
  asVfat = runFor { name = "fixture"; medium = "vfat"; };
  asIso = runFor { name = "fixture"; medium = "iso"; };
  asJson = runFor { name = "fixture"; medium = "json"; };
  elsewhere = runFor { name = "other"; medium = "vfat"; };
in
pkgs.runCommand "test-secrets"
  { nativeBuildInputs = [ pkgs.mtools pkgs.xorriso pkgs.file pkgs.coreutils pkgs.jq ]; }
  ''
    set -euo pipefail

    echo "== a runner, not a derivation: nothing lands in a store path =="
    ${asVfat} side.img
    ${asIso} side.iso
    ${asJson} side.json

    echo "== the consumer finds the file where it was declared, on every medium =="
    mcopy -i side.img ::/sops.age got-vfat
    cmp got-vfat ${fixture}
    xorriso -osirrox on -indev side.iso -extract /sops.age got-iso 2>/dev/null
    cmp got-iso ${fixture}
    jq -r '."/sops.age"' side.json | base64 -d > got-json
    cmp got-json ${fixture}

    echo "== the declared fs is the real one — read it off the artifact =="
    file -b side.img | grep -qi 'fat'
    file -b side.iso | grep -qi 'iso 9660'

    echo "== run twice, byte for byte the same =="
    ${asVfat} again.img && cmp side.img again.img
    ${asIso} again.iso && cmp side.iso again.iso
    ${asJson} again.json && cmp side.json again.json

    echo "== two names, two identities =="
    mine="$(file -b side.img | grep -o 'serial number 0x[0-9a-f]*')"
    ${elsewhere} other.img
    theirs="$(file -b other.img | grep -o 'serial number 0x[0-9a-f]*')"
    [ -n "$mine" ] && [ "$mine" != "$theirs" ]

    touch $out
  ''
