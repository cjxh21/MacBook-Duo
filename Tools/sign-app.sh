#!/bin/zsh
set -euo pipefail
DUO_APP="$1"
DUO_EXTENSION="$2"
DUO_ENTITLEMENTS="$3"
DUO_SIGNING_CONFIG="$HOME/Library/Application Support/MacBook Duo/Signing/identity"
if [[ -z "${DUO_SIGNING_IDENTITY:-}" && -f "$DUO_SIGNING_CONFIG" ]]; then
  DUO_SIGNING_IDENTITY="$(<"$DUO_SIGNING_CONFIG")"
  if [[ ! "$DUO_SIGNING_IDENTITY" =~ '^[[:xdigit:]]{40}$' ]]; then
    print -u2 "Invalid local signing configuration: $DUO_SIGNING_CONFIG"
    exit 1
  fi
fi
DUO_SIGNING_IDENTITY="${DUO_SIGNING_IDENTITY:--}"
codesign --force --sign "$DUO_SIGNING_IDENTITY" --entitlements "$DUO_ENTITLEMENTS" "$DUO_EXTENSION"
codesign --force --sign "$DUO_SIGNING_IDENTITY" "$DUO_APP"
codesign --verify --deep --strict "$DUO_APP"
if [[ "$DUO_SIGNING_IDENTITY" == "-" ]]; then
  print "Signed ad-hoc; use Tools/setup-local-signing.py for a persistent local identity."
else
  print "Signed with the configured persistent identity."
fi
