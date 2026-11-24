#!/usr/bin/env bash
# Fills ./zig-pkg (the project-local package cache) using curl, so `zig build`
# never has to run Zig's own TLS client.
#
# Use this when a dependency fetch fails because Zig cannot verify the server's
# certificate: `error: invalid HTTP response: TlsInitializationFailed`. Zig
# reads trust anchors from fixed places only — six hard-coded bundle files on
# Linux, SystemRootCertificates.keychain and /Library/Keychains/System.keychain
# on macOS — and ignores SSL_CERT_FILE/SSL_CERT_DIR, so a trust store that curl
# uses correctly can still be invisible to Zig. curl does the transfer instead.
#
#   bash tools/seed-deps.sh     # run from the project root, then: ./zig build
#
# Every URL and hash is read out of the manifests themselves, so this follows the
# pins wherever they point. Re-run it after a dependency bump.
set -eu

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fetch_one() { # $1 = archive URL, $2 = content hash declared beside it
  [ -d "zig-pkg/$2" ] && return 0
  printf '  %s\n' "$2"
  curl -fsSL --retry 3 "$1" -o "$tmp/dep.tar.gz"
  mkdir -p "zig-pkg/$2"
  # Archive tarballs wrap the package in one top-level directory.
  tar xzf "$tmp/dep.tar.gz" -C "zig-pkg/$2" --strip-components=1
}

# Each dependency block declares .url immediately followed by .hash, so pair the
# two strings positionally. [[:space:]] rather than \s for BSD grep (macOS).
seed_from() {
  grep -oE '^[[:space:]]*\.(url|hash) = "[^"]*"' "$1" |
    sed 's/.* = "//; s/"$//' |
    paste - - |
    while IFS=$'\t' read -r url hash; do
      [ -n "${url:-}" ] && [ -n "${hash:-}" ] || continue
      fetch_one "$url" "$hash"
    done
}

# BSD wc pads its output with spaces (macOS), so strip it before the caller
# compares counts with -eq.
count_pkgs() {
  if [ -d zig-pkg ]; then
    find zig-pkg -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]'
  else
    printf '0'
  fi
  printf '\n'
}

# Each pass walks one manifest level deeper: the root manifest names three
# dependencies, their manifests name the rest. All declared dependencies are
# fetched, including zig-curl's lazy curl/zlib/mbedtls entries, so a
# -Dlink_vendor=true build works offline too.
for _pass in 1 2 3 4; do
  before=$(count_pkgs)
  seed_from build.zig.zon
  if [ -d zig-pkg ]; then
    find zig-pkg -mindepth 2 -maxdepth 2 -name build.zig.zon > "$tmp/manifests"
    while IFS= read -r manifest; do seed_from "$manifest"; done < "$tmp/manifests"
  fi
  if [ "$(count_pkgs)" -eq "$before" ]; then break; fi
done

printf '%s packages in zig-pkg/\n' "$(count_pkgs)"
