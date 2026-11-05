#!/usr/bin/env sh
set -eu
umask 077

REPO="fin-hq/fin-releases"
SOURCE_REPO="fin-hq/fin"
PUBKEY_B64="/cpK6+QVcSRIrZvkXAn0sSGT6BAuivC4y2a7iHoc0Us="
MODE="auto"
TAG=""
BIN_DIR="${FIN_BIN_DIR:-$HOME/.local/bin}"
tmp=""
staged=""
cleanup() {
  [ -z "$staged" ] || rm -f "$staged"
  [ -z "$tmp" ] || rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

die() { echo "install: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --source) [ "$MODE" = auto ] || die "choose one installation mode"; MODE="source" ;;
    --release)
      [ "$MODE" = auto ] || die "choose one installation mode"
      MODE="release"
      if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then TAG="$2"; shift; fi ;;
    --bin-dir) if [ $# -lt 2 ] || [ -z "$2" ]; then die "--bin-dir requires a directory"; fi; BIN_DIR="$2"; shift ;;
    -h|--help)
      echo "Usage: install.sh [--source | --release [TAG]] [--bin-dir DIR]"
      echo "Release installs require curl, jq, and OpenSSL with Ed25519 support."
      exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

platform() {
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "$os" in linux|darwin) ;; *) die "unsupported OS: $os (use --source)";; esac
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "unsupported architecture: $arch (use --source)" ;;
  esac
  echo "${os}_${arch}"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

place() {
  mkdir -p "$BIN_DIR"
  BIN_DIR=$(cd "$BIN_DIR" && pwd -P)
  [ ! -L "$BIN_DIR/fin" ] || die "destination is a symbolic link"
  [ ! -e "$BIN_DIR/fin" ] || [ -f "$BIN_DIR/fin" ] || die "destination is not a regular file"
  staged=$(mktemp "$BIN_DIR/.fin-install.XXXXXX")
  cp "$1" "$staged"
  chmod 0755 "$staged"
  "$staged" version >/dev/null || die "candidate executable failed its version check"
  mv -f "$staged" "$BIN_DIR/fin"
  staged=""
  echo "installed $BIN_DIR/fin"
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "note: add $BIN_DIR to PATH" ;; esac
}

install_source() {
  need go
  tmp=$(mktemp -d)
  src="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
  if [ ! -f "$src/go.mod" ] || ! grep -q "^module github.com/fin-hq/fin$" "$src/go.mod"; then
    need gh
    if [ -n "$TAG" ]; then gh repo clone "$SOURCE_REPO" "$tmp/src" -- --depth 1 --branch "$TAG" >/dev/null
    else gh repo clone "$SOURCE_REPO" "$tmp/src" -- --depth 1 >/dev/null; fi
    src="$tmp/src"
  fi
  version=$(cd "$src" && git describe --tags --always --dirty 2>/dev/null || echo dev)
  echo "building fin $version"
  (cd "$src" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X github.com/fin-hq/fin/internal/cli/app.Version=$version" -o "$tmp/fin" ./cmd/fin)
  place "$tmp/fin"
}

download() {
  curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-redirs 5 --connect-timeout 15 --max-time 300 --retry 2 --max-filesize "$3" --output "$2" "$1" || die "download failed"
}

install_release() {
  need curl; need openssl; need jq
  [ -z "$TAG" ] || printf '%s\n' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || die "tag must be vX.Y.Z"
  p=$(platform)
  tmp=$(mktemp -d)
  echo "downloading ${TAG:-latest release} for $p"
  manifest_url="https://github.com/$REPO/releases/latest/download/manifest.json"
  [ -z "$TAG" ] || manifest_url="https://github.com/$REPO/releases/download/$TAG/manifest.json"
  download "$manifest_url" "$tmp/manifest.json" 1048576
  manifest_size=$(wc -c < "$tmp/manifest.json" | tr -d '[:space:]')
  if [ "$manifest_size" -eq 0 ] || [ "$manifest_size" -gt 1048576 ]; then die "manifest exceeds size limit"; fi
  jq -e 'type == "object" and (keys == ["payload", "signature"]) and (.payload | type == "string" and length > 0 and length % 4 == 0 and test("^[A-Za-z0-9+/]+={0,2}$")) and (.signature | type == "string" and length == 88 and test("^[A-Za-z0-9+/]+={0,2}$"))' "$tmp/manifest.json" >/dev/null || die "manifest envelope is malformed"
  jq -er '.payload' "$tmp/manifest.json" > "$tmp/payload.b64"
  jq -er '.signature' "$tmp/manifest.json" > "$tmp/signature.b64"
  openssl base64 -d -A -in "$tmp/payload.b64" -out "$tmp/payload.json" || die "invalid manifest payload encoding"
  openssl base64 -d -A -in "$tmp/signature.b64" -out "$tmp/sig.bin" || die "invalid manifest signature encoding"
  if [ ! -s "$tmp/payload.json" ] || [ "$(wc -c < "$tmp/sig.bin" | tr -d '[:space:]')" != 64 ]; then die "manifest envelope is malformed"; fi
  { printf '\060\052\060\005\006\003\053\145\160\003\041\000'; printf '%s\n' "$PUBKEY_B64" | openssl base64 -d -A; } > "$tmp/key.der"
  openssl pkey -pubin -inform DER -in "$tmp/key.der" -out "$tmp/key.pem" 2>/dev/null || die "OpenSSL cannot load the release signing key"
  openssl pkeyutl -verify -pubin -inkey "$tmp/key.pem" -rawin -in "$tmp/payload.json" -sigfile "$tmp/sig.bin" >/dev/null 2>&1 || die "manifest signature verification failed"
  jq -e --arg p "$p" '
    type == "object" and (keys == ["artifacts", "version"]) and
    (.version | type == "string" and test("^v?[0-9]+\\.[0-9]+\\.[0-9]+([+-][0-9A-Za-z.-]+)?$")) and
    (.artifacts | type == "object") and
    (.artifacts[$p] | type == "object" and (keys == ["sha256", "size", "url"]) and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.size | type == "number" and floor == . and . > 0 and . <= 134217728) and
      (.url | type == "string" and startswith("https://")))' "$tmp/payload.json" >/dev/null || die "signed manifest is malformed or does not support $p"
  signed_version=$(jq -r '.version' "$tmp/payload.json")
  [ -z "$TAG" ] || [ "${TAG#v}" = "${signed_version#v}" ] || die "signed version differs from requested tag"
  expected=$(jq -r --arg p "$p" '.artifacts[$p].sha256' "$tmp/payload.json")
  expected_size=$(jq -r --arg p "$p" '.artifacts[$p].size' "$tmp/payload.json")
  artifact_url=$(jq -r --arg p "$p" '.artifacts[$p].url' "$tmp/payload.json")
  [ "$artifact_url" = "https://github.com/$REPO/releases/download/$signed_version/fin_$p" ] || die "artifact URL does not match signed version"
  download "$artifact_url" "$tmp/fin_$p" "$expected_size"
  actual_size=$(wc -c < "$tmp/fin_$p" | tr -d '[:space:]')
  [ "$expected_size" = "$actual_size" ] || die "artifact size mismatch"
  actual=$(sha256_of "$tmp/fin_$p")
  [ "$expected" = "$actual" ] || die "artifact SHA-256 mismatch"
  echo "signature, size, and checksum verified"
  place "$tmp/fin_$p"
}

case "$MODE" in
  source) install_source ;;
  release|auto) install_release ;;
esac
