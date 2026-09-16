# The SINGLE way a bash tool here is assembled: prepend the shared helper lib(s), each
# followed by a newline, then the tool body, wrapped as a writeShellApplication — so
# shellcheck gates every tool at build.
#
#   {
#     pkgs;                  # the tool runs on this
#     name;
#     runtimeInputs ? [];    # exact PATH deps — NOT auto-extended
#     libs ? [ bash-lib ];   # helper .sh files prepended, each + a trailing newline
#     text;                  # the tool body
#   }
{ pkgs, name, runtimeInputs ? [ ], libs ? [ ./bash-lib.sh ], text }:
pkgs.writeShellApplication {
  inherit name runtimeInputs;
  text = pkgs.lib.concatMapStrings (f: builtins.readFile f + "\n") libs + text;
}
