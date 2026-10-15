#!/usr/bin/env bash
# Pin this project to a Zig 0.17 toolchain.
#
# The dependencies (httpx 0.2.2 and zig-curl) declare minimum_zig_version 0.17.0,
# so the project only builds under Zig 0.17. Run `./zig build` instead of a bare
# `zig build` to guarantee the right toolchain regardless of what `zig` resolves
# to on the machine.
#
# Resolution order:
#   1. $ZIG_17 if set and it reports 0.17.x
#   2. the default `zig` if it already reports 0.17.x
#   3. a known local 0.17 toolchain (e.g. the zig snap revision 17037)
set -euo pipefail

is17() {
  case "$("$1" version 2>/dev/null)" in
  0.17*) return 0 ;;
  *) return 1 ;;
  esac
}

if [ -n "${ZIG_17:-}" ]; then
  if is17 "$ZIG_17"; then exec "$ZIG_17" "$@"; fi
  echo "error: ZIG_17=$ZIG_17 is not a Zig 0.17 toolchain" >&2
  exit 1
fi

if command -v zig >/dev/null 2>&1 && is17 zig; then exec zig "$@"; fi

for cand in /snap/zig/*/zig /snap/zig/*/bin/zig; do
  [ -x "$cand" ] || continue
  if is17 "$cand"; then exec "$cand" "$@"; fi
done

echo "error: no Zig 0.17 toolchain found; set ZIG_17 to its path (e.g. /snap/zig/17037/zig)" >&2
exit 1
