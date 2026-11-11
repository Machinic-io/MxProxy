#!/usr/bin/env bash
# Pin this project to a Zig 0.17.1+ toolchain.
#
# build.zig.zon requires minimum_zig_version 0.17.1 (the 0.17.1 bug-fix release
# resolves the 0.17.0 regressions), so the project only builds under Zig 0.17.1+.
# Run `./zig build` instead of a bare `zig build` to guarantee the right
# toolchain regardless of what `zig` resolves to on the machine.
#
# Dependencies (zig-curl, httpx, zig-regex) are URL deps pinned by content hash
# in build.zig.zon; `./zig build` fetches them automatically, so a fresh clone
# builds without manual setup. To develop against a local checkout of a dep
# instead of the fetched package, use Zig's fork override, e.g.
#   ./zig build --fork=../zig-curl    # matched by the package name in its zon
#   ./zig build test --fork=../httpx.zig
# To bump a dep: ./zig fetch --save=<name> <archive-url> and commit the zon diff.
#
# Toolchain resolution order:
#   1. $ZIG_17 if set and it reports 0.17.1+
#   2. the default `zig` if it already reports 0.17.1+
#   3. a known local 0.17.1+ toolchain (snap, Homebrew, Nix, or a tarball in $HOME)
set -euo pipefail

is17() {
  # Accepts Zig 0.17.1+ (build.zig.zon requires 0.17.1; 0.17.0 is rejected).
  local ver patch
  ver="$("$1" version 2>/dev/null)" || return 1
  case "$ver" in
  0.17.*)
    patch="${ver#0.17.}"
    patch="${patch%%[!0-9]*}"
    [ -n "$patch" ] && [ "$patch" -ge 1 ]
    ;;
  *) return 1 ;;
  esac
}

if [ -n "${ZIG_17:-}" ]; then
  if is17 "$ZIG_17"; then exec "$ZIG_17" "$@"; fi
  echo "error: ZIG_17=$ZIG_17 is not a Zig 0.17.1+ toolchain" >&2
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

echo "error: no Zig 0.17.1+ toolchain found (searched PATH, snap, Homebrew, Nix, \$HOME); set ZIG_17 to the path of your 0.17.1+ zig" >&2
exit 1
