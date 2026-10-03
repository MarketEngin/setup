#!/usr/bin/env bash
# Bootstrap: fetch MarketEngin/setup and run install.sh (no manual clone).
#
# One-liner (Linux):
#   curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh | sudo bash -s -- --components all
#
# With token for private MarketEngin releases:
#   curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh \
#     | sudo env QUANT_GITHUB_TOKEN="$QUANT_GITHUB_TOKEN" bash -s -- --components all --channel stable

set -euo pipefail

: "${QUANT_SETUP_URL:=https://github.com/MarketEngin/setup}"
: "${QUANT_SETUP_REF:=main}"
: "${QUANT_GIT_URL:=https://github.com/MarketEngin/MarketEngin.git}"
: "${QUANT_GITHUB_TOKEN:=${GITHUB_TOKEN:-}}"

log() { echo "quant-setup: $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl required"
command -v tar >/dev/null 2>&1 || die "tar required"

# Parse QUANT_SETUP_URL → owner/repo for archive download.
owner_repo=""
if [[ "$QUANT_SETUP_URL" =~ github\.com[:/]+([^/]+)/([^/.]+)(\.git)?/?$ ]]; then
  owner_repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
else
  die "QUANT_SETUP_URL must be a github.com URL (got: $QUANT_SETUP_URL)"
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/quant-setup.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

ARCHIVE="$WORKDIR/setup.tar.gz"
EXTRACT="$WORKDIR/src"
mkdir -p "$EXTRACT"

HDR=()
if [[ -n "${QUANT_GITHUB_TOKEN:-}" ]]; then
  HDR+=(-H "Authorization: Bearer ${QUANT_GITHUB_TOKEN}")
  HDR+=(-H "X-GitHub-Api-Version: 2022-11-28")
fi

# Prefer codeload archive (works for public; token helps for private).
ARCHIVE_URL="https://codeload.github.com/${owner_repo}/tar.gz/refs/heads/${QUANT_SETUP_REF}"
log "fetching ${owner_repo}@${QUANT_SETUP_REF}"
if ! curl -fsSL "${HDR[@]}" -o "$ARCHIVE" "$ARCHIVE_URL"; then
  # Fallback: git clone (SSH or tokenized HTTPS)
  die "failed to download setup archive from $ARCHIVE_URL"
fi

tar -xzf "$ARCHIVE" -C "$EXTRACT"
# GitHub archives extract to {repo}-{ref}/
ROOT="$(find "$EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -n "$ROOT" && -f "$ROOT/install.sh" ]] || die "install.sh missing in archive"
[[ -f "$ROOT/lib.sh" ]] || die "lib.sh missing in archive"

chmod +x "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/lib.sh" 2>/dev/null || true

export QUANT_GIT_URL QUANT_GITHUB_TOKEN QUANT_SETUP_URL QUANT_SETUP_REF
log "running install.sh ${*:-}"
exec "$ROOT/install.sh" "$@"
