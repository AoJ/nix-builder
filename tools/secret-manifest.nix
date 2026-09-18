# The manifest both producers write and every runner reads: one line per file, and the
# ONE place that decides its shape, so `secrets` and `personalize` cannot drift apart.
#
#   <kind>\t<spec>\t<target>\t<mode>
#
# kind is where the bytes come from, and nothing here looks at what they ARE: `text` is
# already in the store (the caller put it there by declaring it in nix — only do that with
# material that is already encrypted), `env` and `file` are resolved when the runner runs.
{ pkgs }:

let
  inherit (pkgs) lib;

  forms = [ "text" "env" "file" ];

  specOf = name: f:
    let
      given = lib.filter (k: f.content.${k} or null != null) forms;
    in
    if lib.length given != 1
    then throw ("secrets(${name}): ${f.target} must declare exactly one of"
      + " content.text / content.env / content.file, got ${builtins.toJSON given}")
    else
      let kind = lib.head given; in
      {
        inherit kind;
        spec =
          if kind == "text"
          # Declared in nix, so it lives in the store either way; writing it out is what
          # gives the runner a path to read.
          then pkgs.writeText "${name}-${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" f.target)}"
            f.content.text
          else f.content.${kind};
      };
in
{ name, files }:

pkgs.writeText "${name}-manifest" (lib.concatMapStrings
  (f:
    let s = specOf name f; in
    "${s.kind}\t${s.spec}\t${f.target}\t${f.mode}\n")
  files)
