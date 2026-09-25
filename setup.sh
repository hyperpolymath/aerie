#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Aerie — Universal Setup Script (the zero-prerequisite path).
#
# Guaranteed to work straight after `git clone` with only core OS tools:
# bash and curl (plus tar/xz for the Zig archive). It detects the platform,
# installs whatever the Justfile needs that is missing — the estate task
# runner `just` and the Zig toolchain pinned in .tool-versions — into a
# user-local bin directory (no sudo), then hands off to the Justfile via
# `just doctor`.
#
# Safe to re-run: tools already present are left untouched.

set -euo pipefail

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

echo "═══════════════════════════════════════════════════"
echo "  Aerie — Setup (zero-prerequisite bootstrap)"
echo "═══════════════════════════════════════════════════"
echo ""

OS="$(uname -s)"
ARCH="$(uname -m)"
echo "Platform: $OS $ARCH"
CURRENT_SHELL="$(basename "${SHELL:-unknown}" 2>/dev/null || echo "unknown")"
echo "Shell: $CURRENT_SHELL"
echo ""

# Normalise the CPU architecture to the naming used by both tool vendors.
case "$ARCH" in
  x86_64 | amd64) ARCH=x86_64 ;;
  arm64 | aarch64) ARCH=aarch64 ;;
  *) die "Unsupported CPU architecture: $ARCH (need x86_64 or aarch64)" ;;
esac

# User-local install prefix. Everything this script installs lands here;
# nothing touches /usr/local, nothing needs sudo.
BIN_DIR="${AERIE_BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}"
DATA_DIR="${AERIE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/aerie}"
mkdir -p "$BIN_DIR" "$DATA_DIR"
PATH_PREPENDED=""
case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *)
    PATH="$BIN_DIR:$PATH"
    export PATH
    PATH_PREPENDED=1
    ;;
esac

have curl || die "curl is required (it is the only tool setup.sh cannot bootstrap). Install it with your OS package manager."

download() { # url dest
  curl -fSL --proto '=https' --tlsv1.2 --retry 3 -o "$2" "$1"
}

# ──────────────────────────────────────────────────────────────── just

latest_release_tag() { # owner/repo -> tag, or empty
  local url
  url="$(curl -fsSI -o /dev/null -w '%{redirect_url}' \
    "https://github.com/$1/releases/latest" 2>/dev/null)" || return 0
  [ -n "$url" ] && printf '%s\n' "${url##*/}" || return 0
}

install_just() {
  if have just; then
    echo "just: already present ($(just --version 2>/dev/null | head -1))"
    return 0
  fi
  echo "just: not found — installing into $BIN_DIR"

  local target ext
  case "$OS" in
    Linux)  target="$ARCH-unknown-linux-musl" ext=tar.gz ;;
    Darwin) target="$ARCH-apple-darwin"       ext=tar.gz ;;
    *)      target="" ;;
  esac

  local ver
  ver="${JUST_VERSION:-$(latest_release_tag casey/just)}"
  ver="${ver:-1.40.0}" # last-resort pin if the releases redirect is unreachable

  if [ -n "$target" ] && download "https://github.com/casey/just/releases/download/$ver/just-$ver-$target.$ext" "$TMPD/just.$ext"; then
    tar -xzf "$TMPD/just.$ext" -C "$TMPD" just
    install -m 755 "$TMPD/just" "$BIN_DIR/just"
  elif have cargo; then
    echo "just: binary download failed — falling back to cargo install just"
    cargo install just
  elif have brew; then
    echo "just: binary download failed — falling back to brew install just"
    brew install just
  else
    die "could not install just. Install it manually: https://just.systems/man/en/installation.html"
  fi

  have just || die "just is still not on PATH after the install attempt ($BIN_DIR must be on PATH)."
  echo "just: installed ($(just --version 2>/dev/null | head -1))"
}

# ──────────────────────────────────────────────────────────────── zig

pinned_zig_version() {
  if [ -f .tool-versions ]; then
    awk '$1 == "zig" { print $2; exit }' .tool-versions
  fi
}

# Extract the tarball URL + shasum for <arch>-<os> out of the ziglang.org
# release index without needing jq.
zig_index_field() { # version arch-os field(tarball|shasum) -> value, or empty
  curl -fsSL "https://ziglang.org/download/index.json" 2>/dev/null | awk -v v="\"$1\"" -v k="\"$2\"" -v f="\"$3\"" '
    $0 ~ "^  " v ": {" { inver = 1; next }
    inver && $0 ~ "^  }" { exit }
    inver && $0 ~ "^    " k ": {" { inkey = 1; next }
    inkey && $0 ~ "^    }" { exit }
    inkey && $0 ~ f {
      sub(/^[^"]*"[^"]*"[^"]*"/, "")
      sub(/".*/, "")
      print
      exit
    }
  '
}

install_zig() {
  if have zig; then
    echo "zig:  already present ($(zig version 2>/dev/null | head -1))"
    return 0
  fi

  local ver os_tag
  ver="${ZIG_VERSION:-$(pinned_zig_version)}"
  ver="${ver:-0.15.2}" # last-resort pin; keep in step with build.zig / mise.toml
  case "$OS" in
    Linux)  os_tag=linux ;;
    Darwin) os_tag=macos ;;
    *)      os_tag="" ;;
  esac

  echo "zig:  not found — installing $ver into $DATA_DIR"

  local url sha="" key="${ARCH}-${os_tag}"
  if [ -n "$os_tag" ]; then
    url="$(zig_index_field "$ver" "$key" tarball)"
    sha="$(zig_index_field "$ver" "$key" shasum)"
    # Fallback when the index is unreachable: 0.14+ asset naming.
    url="${url:-https://ziglang.org/download/$ver/zig-$ARCH-$os_tag-$ver.tar.xz}"
  fi

  if [ -n "${url:-}" ] && download "$url" "$TMPD/zig.tar.xz"; then
    if [ -n "$sha" ]; then
      local actual=""
      if have sha256sum; then
        actual="$(sha256sum "$TMPD/zig.tar.xz" | awk '{print $1}')"
      elif have shasum; then
        actual="$(shasum -a 256 "$TMPD/zig.tar.xz" | awk '{print $1}')"
      fi
      if [ -n "$actual" ]; then
        [ "$actual" = "$sha" ] || die "zig archive checksum mismatch — aborting."
        echo "zig:  checksum verified"
      else
        echo "zig:  WARNING: no sha256 tool available — skipping checksum verification"
      fi
    fi
    tar -xJf "$TMPD/zig.tar.xz" -C "$TMPD" 2>/dev/null \
      || die "could not extract the Zig archive — install xz (e.g. apt/dnf/brew install xz) and re-run."
    local dest="$DATA_DIR/zig-$ver"
    rm -rf "$dest"
    mv "$TMPD"/zig-* "$dest"
    ln -sfn "$dest/zig" "$BIN_DIR/zig"
  elif have mise; then
    echo "zig:  download failed — falling back to mise (mise.toml pins $ver)"
    mise install "zig@$ver"
  elif have brew; then
    echo "zig:  download failed — falling back to brew install zig"
    brew install zig
  else
    echo "zig:  could not install automatically."
    echo "      Get Zig $ver from https://ziglang.org/download/ and put it on PATH."
    return 1
  fi

  if have zig; then
    echo "zig:  installed ($(zig version 2>/dev/null | head -1))"
  else
    echo "zig:  still not on PATH after the install attempt."
    return 1
  fi
}

# ──────────────────────────────────────────────────────────────── run

install_just
ZIG_RC=0
install_zig || ZIG_RC=1

if [ -n "$PATH_PREPENDED" ]; then
  echo ""
  echo "NOTE: installed tools live in $BIN_DIR, which is not yet on your PATH."
  echo "      It was added for this session only. Make it permanent with:"
  echo ""
  echo "        echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.${CURRENT_SHELL}rc"
  echo ""
fi

echo ""
echo "Running diagnostics..."
echo ""
if ! just doctor; then
  echo ""
  echo "Some checks failed above. Re-running ./setup.sh will retry the automatic"
  echo "repair; anything it cannot fix is listed with a manual install hint."
  exit 1
fi

echo ""
if [ "$ZIG_RC" -eq 0 ]; then
  echo "Setup complete. Next: just build && just test   ('just help-me' for workflows)."
else
  echo "Setup mostly complete, but Zig still needs a manual install (see above);"
  echo "the docs-only and container paths work without it."
fi
