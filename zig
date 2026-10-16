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
#   3. a known local 0.17 toolchain (snap, Homebrew, Nix, or a tarball in $HOME)
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

# Look for zig in common places
for cand in /snap/zig/*/zig /snap/zig/*/bin/zig \
            /opt/homebrew/bin/zig /opt/homebrew/Cellar/zig/*/bin/zig \
            /usr/local/bin/zig /usr/local/Cellar/zig/*/bin/zig \
            "$HOME/.nix-profile/bin/zig" "$HOME"/zig-*/zig; do
  [ -x "$cand" ] || continue
  if is17 "$cand"; then exec "$cand" "$@"; fi
done

echo "error: no Zig 0.17 toolchain found (searched PATH, snap, Homebrew, Nix, \$HOME); set ZIG_17 to the path of your 0.17 zig" >&2
exit 1
