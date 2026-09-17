# The third refusal: the key being planted must belong to THIS host — its public half a
# recipient of the host's own bundle. Planting another host's key otherwise surfaces as an
# undecryptable boot on a machine that may only have a serial console. Runs before any
# artifact write, like every other check.
#
# Prepended by the block: recipient_bundle, recipient_key_target (both empty when the
# caller declared no check), manifest.
check_recipient() {
  [ -n "${recipient_bundle:-}" ] || return 0

  key_src=""
  while IFS=$'\t' read -r src dest; do
    [ "$dest" = "$recipient_key_target" ] && key_src=$src
  done < "$manifest"
  [ -n "$key_src" ] || fatal "refusal: no file in this run targets $recipient_key_target"
  [ -e "$key_src" ] || fatal "refusal: no such key file: $key_src"

  sc=0
  pub=$(age-keygen -y "$key_src" 2>/dev/null) || sc=$?
  { [ "$sc" = 0 ] && [ -n "$pub" ]; } \
    || fatal "refusal: $key_src is not an age identity"

  # Committed bundles are YAML on some hosts and JSON on others; yq reads both, and -oy
  # keeps the output a raw scalar for both (JSON input would otherwise come back quoted).
  # A bundle this check cannot READ is a named refusal, not a skipped check.
  sc=0
  recipients=$(yq -oy '.sops.age[].recipient' "$recipient_bundle" 2>/dev/null) || sc=$?
  { [ "$sc" = 0 ] && [ -n "$recipients" ] && [ "$recipients" != null ]; } \
    || fatal "refusal: cannot read recipients out of $recipient_bundle"

  grep -qxF "$pub" <<<"$recipients" \
    || fatal "refusal: the key is not a recipient of $recipient_bundle"
  info "key belongs to this host: $pub"
}
check_recipient
