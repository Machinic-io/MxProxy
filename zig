#!/usr/bin/env bash
# Pin this project to a Zig 0.17.1+ toolchain and bootstrap the local path deps.
#
# build.zig.zon requires minimum_zig_version 0.17.1 (the 0.17.1 bug-fix release
# resolves the 0.17.0 regressions), so the project only builds under Zig 0.17.1+.
# Run `./zig build` instead of a bare `zig build` to guarantee the right
# toolchain regardless of what `zig` resolves to on the machine.
#
# build.zig.zon links zig-curl, httpx and zig-regex by sibling path (../zig-curl,
# ../httpx.zig and ../zig-regex). If a sibling is missing it is cloned from
# GitHub at the pinned commit, so a fresh checkout builds without manual setup.
# A present sibling (one that has a build.zig.zon) is left untouched, so a local
# pin or edit survives.
#
# Toolchain resolution order:
#   1. $ZIG_17 if set and it reports 0.17.1+
#   2. the default `zig` if it already reports 0.17.1+
#   3. a known local 0.17.1+ toolchain (snap, Homebrew, Nix, or a tarball in $HOME)
set -euo pipefail

# --- Bootstrap local path deps ------------------------------------------------
# The deps live as siblings of this checkout (one dir up).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPS_ROOT="$(dirname "$SCRIPT_DIR")"

# Pinned dep commits (must match .github/workflows/ci.yml). Override with the
# same env names to point the bootstrap at a different commit.
ZIG_CURL_REPO="https://github.com/jiacai2050/zig-curl"
HTTPX_REPO="https://github.com/muhammad-fiaz/httpx.zig"
ZIG_REGEX_REPO="https://github.com/zig-utils/zig-regex"
ZIG_CURL_REF="${ZIG_CURL_REF:-0bc73f43cbd736fb7801b31b91c2ea0cca145c67}"
HTTPX_REF="${HTTPX_REF:-cbed04b165d3301e5fa9ff7339f64072c57bc8cb}"
ZIG_REGEX_REF="${ZIG_REGEX_REF:-16df9870ca4a4ec8d0b932e90a62a8b3fb9af563}"

# Ensure the sibling $1 is a checkout of $2 at $3; clone it if it is missing.
# A sibling that already has a build.zig.zon is treated as present and kept.
ensure_dep() {
  local name="$1" repo="$2" ref="$3"
  local dest="$DEPS_ROOT/$name"
  if [ -f "$dest/build.zig.zon" ]; then
    return 0
  fi
  echo "info: $name missing; cloning $repo @ ${ref:0:12} into $dest"
  rm -rf "$dest"
  git clone "$repo" "$dest"
  git -C "$dest" fetch origin "$ref"
  git -C "$dest" checkout "$ref"
}

ensure_dep zig-curl "$ZIG_CURL_REPO" "$ZIG_CURL_REF"
ensure_dep httpx.zig "$HTTPX_REPO" "$HTTPX_REF"
ensure_dep zig-regex "$ZIG_REGEX_REPO" "$ZIG_REGEX_REF"
# --- End bootstrap ------------------------------------------------------------

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
