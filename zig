#!/usr/bin/env bash
# Pin this project to a Zig 0.17 toolchain and bootstrap the local path deps.
#
# The dependencies (httpx 0.2.2 and zig-curl) declare minimum_zig_version 0.17.0,
# so the project only builds under Zig 0.17. Run `./zig build` instead of a bare
# `zig build` to guarantee the right toolchain regardless of what `zig` resolves
# to on the machine.
#
# build.zig.zon links zig-curl and httpx by sibling path (../zig-curl and
# ../httpx.zig). If a sibling is missing it is cloned from GitHub at the pinned
# commit, so a fresh checkout builds without manual setup. A present sibling
# (one that has a build.zig.zon) is left untouched, so a local pin or edit
# survives.
#
# Toolchain resolution order:
#   1. $ZIG_17 if set and it reports 0.17.x
#   2. the default `zig` if it already reports 0.17.x
#   3. a known local 0.17 toolchain (snap, Homebrew, Nix, or a tarball in $HOME)
set -euo pipefail

# --- Bootstrap local path deps ------------------------------------------------
# The deps live as siblings of this checkout (one dir up).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPS_ROOT="$(dirname "$SCRIPT_DIR")"

# Pinned dep commits (must match .github/workflows/ci.yml). Override with the
# same env names to point the bootstrap at a different commit.
ZIG_CURL_REPO="https://github.com/jiacai2050/zig-curl"
HTTPX_REPO="https://github.com/muhammad-fiaz/httpx.zig"
ZIG_CURL_REF="${ZIG_CURL_REF:-9c0f1d211ad22dd0f4c20aa54060c1d9f163595a}"
HTTPX_REF="${HTTPX_REF:-deacfacea9a83c060d65ad65da1e40fa2edadc43}"

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
# --- End bootstrap ------------------------------------------------------------

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
