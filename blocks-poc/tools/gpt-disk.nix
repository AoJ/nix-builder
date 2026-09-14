{ pkgs, bashTool, ids }:

let
  inherit (pkgs) lib;
  tool = bashTool {
    name = "gpt-disk";
    runtimeInputs = [ pkgs.coreutils pkgs.gptfdisk pkgs.jq ];
    text = builtins.readFile ./gpt-disk.sh;
  };
  typeCode = { vfat = "ef00"; ext4 = "8300"; squashfs = "8300"; };
in
{ name, partitions }:

let
  manifest = pkgs.writeText "${name}-disk-manifest" (lib.concatMapStrings (p:
    let
      code = p.code or typeCode.${p.fs};
      guid = ids.uuid "${name}:part:${p.label}";
    in
    "${p.label}\t${code}\t${p.fs}\t${p.img}\t${guid}\n") partitions);
in
pkgs.runCommand "${name}.img" { outputs = [ "out" "layout" ]; }
  ''
    ${tool}/bin/gpt-disk "$out" "$layout" \
      ${lib.escapeShellArg (ids.uuid "${name}:disk")} ${manifest}
  ''
