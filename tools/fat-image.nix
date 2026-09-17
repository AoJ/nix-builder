{ pkgs, bashTool }:

let
  inherit (pkgs) lib;
  app = bashTool {
    name = "fat-image";
    runtimeInputs = [ pkgs.coreutils pkgs.dosfstools pkgs.mtools ];
    text = builtins.readFile ./fat-image.sh;
  };

  # sizeMiB is a FLOOR: an empty manifest (a slot) gets exactly this size, payload can only
  # grow it.
  build = { name, label, volumeId, files ? [ ], sizeMiB ? 1, fat ? "auto" }:
    let
      manifest = pkgs.writeText "${name}-${lib.toLower label}-manifest"
        (lib.concatMapStrings (f: "${f.source}\t${f.target}\n") files);
    in
    pkgs.runCommand "${name}-${lib.toLower label}.img" { }
      ''
        ${app}/bin/fat-image "$out" ${lib.escapeShellArg label} ${lib.escapeShellArg volumeId} \
          ${toString (sizeMiB * 1048576)} ${manifest} ${lib.escapeShellArg fat}
      '';
in
{ inherit app build; }
