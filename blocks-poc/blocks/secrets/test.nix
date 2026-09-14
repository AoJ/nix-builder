{ pkgs, tools }:

let
  secrets = import ./default.nix { inherit pkgs tools; };

  fixture = pkgs.writeText "age-key-fixture" "AGE-SECRET-KEY-FIXTURE";
  files = [ { target = "/sops.age"; source = fixture; } ];

  asVfat = secrets { name = "fixture"; inherit files; medium = "vfat"; };
  asIso = secrets { name = "fixture"; inherit files; medium = "iso"; };
  asJson = secrets { name = "fixture"; inherit files; medium = "json"; };

  again = d: d.overrideAttrs (_: { determinismProbe = "2"; });
  elsewhere = secrets { name = "other"; inherit files; medium = "vfat"; };
in
pkgs.runCommand "test-secrets"
  { nativeBuildInputs = [ pkgs.mtools pkgs.xorriso pkgs.file pkgs.coreutils pkgs.jq ]; }
  ''
    set -euo pipefail

    echo "== the consumer finds the file where it was declared, on every medium =="
    mcopy -i ${asVfat.file} ::/sops.age got-vfat
    cmp got-vfat ${fixture}
    xorriso -osirrox on -indev ${asIso.file} -extract /sops.age got-iso 2>/dev/null
    cmp got-iso ${fixture}
    jq -r '."/sops.age"' ${asJson.file} | base64 -d > got-json
    cmp got-json ${fixture}

    echo "== the declared fs is the real one — read it off the artifact =="
    [ ${asVfat.fs} = vfat ] && file -b ${asVfat.file} | grep -qi 'fat'
    [ ${asIso.fs} = iso9660 ] && file -b ${asIso.file} | grep -qi 'iso 9660'

    echo "== built twice, byte for byte the same =="
    cmp ${asVfat.file} ${again asVfat.file}
    cmp ${asIso.file} ${again asIso.file}
    cmp ${asJson.file} ${again asJson.file}

    echo "== two names, two identities =="
    mine="$(file -b ${asVfat.file} | grep -o 'serial number 0x[0-9a-f]*')"
    theirs="$(file -b ${elsewhere.file} | grep -o 'serial number 0x[0-9a-f]*')"
    [ -n "$mine" ] && [ "$mine" != "$theirs" ]

    touch $out
  ''
