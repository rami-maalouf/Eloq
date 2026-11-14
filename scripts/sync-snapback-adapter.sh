#!/usr/bin/env bash
# copy the snapback4-exact adapter from its snapback branch into the exact
# checkout eloq builds against, where exact's scripts expect it at snapback4/.
# edit the adapter in the snapback checkout, never in the copy.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
from="${SNAPBACK_ADAPTER:-$root/snapback/snapback4/packages/snapback4-exact}"
to="${EXACT_CHECKOUT:-$root/expo-exact-eloq}/snapback4"
[ -f "$from/Cargo.toml" ] || { echo "no adapter at $from" >&2; exit 1; }
mkdir -p "$to"
rsync -a --delete --exclude target --exclude 'ts/.cache' "$from/" "$to/"
echo "synced $(git -C "$from" log -1 --format='%h %s' | cut -c1-80) -> $to"
