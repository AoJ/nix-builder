{ pkgs, bashTool }:

let
  inherit (pkgs) lib;
  tool = bashTool {
    name = "fat-image";
    runtimeInputs = [ pkgs.coreutils pkgs.dosfstools pkgs.mtools ];
    text = builtins.readFile ./fat-image.sh;
  };
in
{ name, label, volumeId, files ? [ ], slackMiB ? 1, fat ? "auto" }:

let
  manifest = pkgs.writeText "${name}-${lib.toLower label}-manifest"
    (lib.concatMapStrings (f: "${f.source}\t${f.target}\n") files);
in
pkgs.runCommand "${name}-${lib.toLower label}.img" { }
  ''
    ${tool}/bin/fat-image "$out" ${lib.escapeShellArg label} ${lib.escapeShellArg volumeId} \
      ${toString (slackMiB * 1048576)} ${manifest} ${lib.escapeShellArg fat}
  ''
