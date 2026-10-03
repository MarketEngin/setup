#!/usr/bin/env bash
# Unified quant stack installer / upgrader.
#
#   sudo ./deploy/install.sh --components all
#   sudo ./deploy/install.sh --channel pre-release --components all
#   sudo ./deploy/install.sh --upgrade --channel stable --components sessionizer,quant
#   sudo ./deploy/install.sh --source local --bin-src ./target/release --components quant,lens
#   sudo ./deploy/install.sh --source url --url https://…/quant-linux-amd64.tar.gz --components all
#
# Env: PREFIX DATA_DIR QUANT_GIT_URL QUANT_GITHUB_TOKEN|GITHUB_TOKEN
#      BIN_SRC ENABLE DRY_RUN=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PREFIX="${PREFIX:-/opt/quant}"
DATA_DIR="${DATA_DIR:-/var/lib/quant}"
ENABLE="${ENABLE:-0}"
DRY_RUN="${DRY_RUN:-0}"

COMPONENTS_RAW=""
CHANNEL=""
SOURCE=""          # git|local|url (resolved)
BIN_SRC_OPT=""
URL_OPT=""
UPGRADE=0
RESTART_SESSIONIZER=1
RESTART_CAPTURE=0
COMPOSE_PATH=""

usage() {
  cat <<'EOF'
Usage: install.sh [options]

  --components LIST   capture,sessionizer,quant,lens,verify or all
  --channel NAME      stable | pre-release (default: prompt / stable)
  --source MODE       git (default) | local | url
  --bin-src DIR       local binary directory (implies --source local)
  --url URL           archive URL (implies --source url)
  --upgrade           upgrade if newer version on channel (git); else no-op
  --restart-sessionizer / --no-restart-sessionizer
  --restart-capture
  --compose PATH      with ENABLE=1, run: quant -f PATH up -d
  --dry-run
  -h, --help

Env: PREFIX=/opt/quant DATA_DIR=/var/lib/quant QUANT_GIT_URL=…
     QUANT_GITHUB_TOKEN|GITHUB_TOKEN  (private GitHub: Contents read)
     BIN_SRC=… ENABLE=0|1
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --components) COMPONENTS_RAW="${2:-}"; shift 2 ;;
    --channel) CHANNEL="$(quant_normalize_channel "${2:-}")"; shift 2 ;;
    --source) SOURCE="${2:-}"; shift 2 ;;
    --bin-src) BIN_SRC_OPT="${2:-}"; SOURCE="${SOURCE:-local}"; shift 2 ;;
    --url) URL_OPT="${2:-}"; SOURCE="${SOURCE:-url}"; shift 2 ;;
    --upgrade) UPGRADE=1; shift ;;
    --restart-sessionizer) RESTART_SESSIONIZER=1; shift ;;
    --no-restart-sessionizer) RESTART_SESSIONIZER=0; shift ;;
    --restart-capture) RESTART_CAPTURE=1; shift ;;
    --compose) COMPOSE_PATH="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) quant_die "unknown arg: $1" ;;
  esac
done

# Resolve source: explicit > BIN_SRC env > url flag > git default
if [[ -z "$SOURCE" ]]; then
  if [[ -n "${BIN_SRC_OPT}" || -n "${BIN_SRC:-}" ]]; then
    SOURCE=local
    BIN_SRC_OPT="${BIN_SRC_OPT:-$BIN_SRC}"
  elif [[ -n "$URL_OPT" ]]; then
    SOURCE=url
  else
    SOURCE=git
  fi
fi

case "$SOURCE" in
  git|local|url) ;;
  *) quant_die "--source must be git|local|url" ;;
esac

COMPONENTS=()
while IFS= read -r _c; do
  [[ -n "$_c" ]] && COMPONENTS+=("$_c")
done < <(quant_parse_components "$COMPONENTS_RAW")
[[ ${#COMPONENTS[@]} -gt 0 ]] || quant_die "no components selected"

if [[ -z "$CHANNEL" ]]; then
  CHANNEL="$(quant_prompt_channel)"
fi
CHANNEL="$(quant_normalize_channel "$CHANNEL")"

quant_log "prefix=$PREFIX data=$DATA_DIR source=$SOURCE channel=$CHANNEL upgrade=$UPGRADE"
quant_log "components: ${COMPONENTS[*]}"

NEED_ROOT=0
if [[ "$(uname -s)" == "Linux" ]] && [[ "$DRY_RUN" != "1" ]]; then
  NEED_ROOT=1
fi
# Installing into /opt typically needs root; allow dry-run / non-root PREFIX elsewhere
if [[ "$NEED_ROOT" == "1" && "$(id -u)" -ne 0 && "$PREFIX" == /opt/* ]]; then
  quant_die "run as root (sudo) to install under $PREFIX"
fi

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_SRC="$REPO_ROOT/configs"
UNIT_SRC="$REPO_ROOT/deploy/systemd"
# Prefer templates next to examples shipped in deploy/systemd
TEMPLATE_SRC="$UNIT_SRC"
if [[ ! -f "$TEMPLATE_SRC/quant-tape@.target" ]]; then
  TEMPLATE_SRC="$REPO_ROOT/tools/quant/src/adapters/supervisor/unit_templates"
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/quant-install.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

STAGE_BIN="$WORKDIR/stage/bin"
mkdir -p "$STAGE_BIN"

VERSION_STR=""
SOURCE_EXTRA=""

resolve_git() {
  quant_log "listing tags from $QUANT_GIT_URL"
  local tags latest
  tags="$(quant_list_remote_tags "$QUANT_GIT_URL")" || quant_die "failed to list tags from $QUANT_GIT_URL"
  latest="$(printf '%s\n' "$tags" | quant_pick_latest_tag "$CHANNEL")" \
    || quant_die "no $CHANNEL tags found at $QUANT_GIT_URL (want vX.Y.Z or vX.Y.Z-devN)"
  quant_log "latest $CHANNEL tag: $latest"

  if [[ "$UPGRADE" == "1" ]]; then
    local installed=""
    installed="$(quant_read_installed_version "$PREFIX" 2>/dev/null || true)"
    if [[ -n "$installed" ]]; then
      if ! quant_tag_matches_channel "$installed" "$CHANNEL"; then
        quant_log "installed version $installed is other channel; will install $latest"
      elif ! quant_version_gt "$latest" "$installed"; then
        quant_log "No newer $CHANNEL version (installed=$installed, latest=$latest)"
        exit 0
      else
        quant_log "upgrade $installed → $latest"
      fi
    fi
  fi

  VERSION_STR="$latest"
  SOURCE_EXTRA="$QUANT_GIT_URL@$latest"

  local archive="" checkout="" bin_dir=""
  mkdir -p "$WORKDIR/fetch"
  if archive="$(quant_fetch_release_asset "$latest" "$WORKDIR/fetch")"; then
    quant_extract_archive "$archive" "$WORKDIR/extract"
    local -a need_bins=()
    local c
    for c in "${COMPONENTS[@]}"; do
      need_bins+=("$(quant_bin_for_component "$c")")
    done
    bin_dir="$(quant_find_bin_dir "$WORKDIR/extract" "${need_bins[@]}")" \
      || quant_die "archive missing required binaries: ${need_bins[*]}"
    quant_stage_bins_from_dir "$bin_dir" "$STAGE_BIN" "${COMPONENTS[@]}"
  else
    quant_log "no release asset; building from git tag $latest"
    checkout="$QUANT_CACHE_DIR/src"
    if [[ "$DRY_RUN" == "1" ]]; then
      quant_log "DRY-RUN would clone $latest and cargo build"
      # Stage empty placeholders message only
      return 0
    fi
    quant_clone_tag "$latest" "$checkout"
    bin_dir="$(quant_build_from_checkout "$checkout" "${COMPONENTS[@]}")"
    quant_stage_bins_from_dir "$bin_dir" "$STAGE_BIN" "${COMPONENTS[@]}"
    # Config/examples from checkout when building from git
    if [[ -d "$checkout/configs" ]]; then
      CONFIG_SRC="$checkout/configs"
    fi
    if [[ -d "$checkout/deploy/systemd" ]]; then
      TEMPLATE_SRC="$checkout/deploy/systemd"
    fi
  fi
}

resolve_local() {
  local dir="${BIN_SRC_OPT:-${BIN_SRC:-$REPO_ROOT/target/release}}"
  [[ -d "$dir" ]] || quant_die "bin-src not a directory: $dir"
  VERSION_STR="local"
  if [[ -f "$dir/VERSION" ]]; then
    VERSION_STR="$(tr -d '[:space:]' <"$dir/VERSION")"
  elif [[ -f "$PREFIX/VERSION" && "$UPGRADE" != "1" ]]; then
    :
  fi
  SOURCE_EXTRA="$dir"
  quant_stage_bins_from_dir "$dir" "$STAGE_BIN" "${COMPONENTS[@]}"
  # Local mode: skip git version gate (always install)
}

resolve_url() {
  local url="${URL_OPT:-}"
  [[ -n "$url" ]] || quant_die "--url required for --source url"
  VERSION_STR="$(basename "$url")"
  VERSION_STR="${VERSION_STR%.tar.gz}"
  VERSION_STR="${VERSION_STR%.tgz}"
  VERSION_STR="${VERSION_STR%.zip}"
  SOURCE_EXTRA="$url"
  local archive="$WORKDIR/download.bin"
  if [[ "$DRY_RUN" == "1" ]]; then
    quant_log "DRY-RUN would download $url"
    return 0
  fi
  quant_download "$url" "$archive"
  quant_extract_archive "$archive" "$WORKDIR/extract"
  if [[ -f "$WORKDIR/extract/VERSION" ]]; then
    VERSION_STR="$(tr -d '[:space:]' <"$WORKDIR/extract/VERSION")"
  elif [[ -f "$WORKDIR/extract/bin/VERSION" ]]; then
    VERSION_STR="$(tr -d '[:space:]' <"$WORKDIR/extract/bin/VERSION")"
  fi
  local -a need_bins=()
  local c
  for c in "${COMPONENTS[@]}"; do
    need_bins+=("$(quant_bin_for_component "$c")")
  done
  local bin_dir
  bin_dir="$(quant_find_bin_dir "$WORKDIR/extract" "${need_bins[@]}")" \
    || quant_die "archive missing required binaries: ${need_bins[*]}"
  quant_stage_bins_from_dir "$bin_dir" "$STAGE_BIN" "${COMPONENTS[@]}"
}

case "$SOURCE" in
  git) resolve_git ;;
  local) resolve_local ;;
  url) resolve_url ;;
esac

if [[ "$DRY_RUN" == "1" && "$SOURCE" == "git" && ! -d "$STAGE_BIN" ]]; then
  quant_log "DRY-RUN staging skipped for git build path"
fi

# For dry-run git without staging, still show plan
if [[ "$DRY_RUN" == "1" ]]; then
  quant_log "DRY-RUN would install version=${VERSION_STR:-?} to $PREFIX"
fi

quant_ensure_user_and_dirs "$PREFIX" "$DATA_DIR"

# Install binaries
has_component() {
  local want="$1" c
  for c in "${COMPONENTS[@]}"; do
    [[ "$c" == "$want" ]] && return 0
  done
  return 1
}

if [[ "$DRY_RUN" != "1" || -d "$STAGE_BIN" ]]; then
  local_c=""
  for local_c in "${COMPONENTS[@]}"; do
    bin="$(quant_bin_for_component "$local_c")"
    if [[ -f "$STAGE_BIN/$bin" ]]; then
      quant_atomic_install_bin "$STAGE_BIN/$bin" "$PREFIX/bin/$bin"
      quant_log "installed $PREFIX/bin/$bin"
    elif [[ "$DRY_RUN" == "1" ]]; then
      quant_log "DRY-RUN would install $bin"
    else
      quant_die "staged binary missing: $STAGE_BIN/$bin"
    fi
  done
fi

# Config examples + seed live configs
install_example() {
  local name="$1"
  local src="$CONFIG_SRC/$name"
  if [[ ! -f "$src" ]]; then
    quant_log "warning: missing example $src (skip)"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    quant_log "DRY-RUN install example $name"
    return 0
  fi
  install -m 644 "$src" "$PREFIX/config/$name"
}

seed_live_config() {
  local example="$1" live="$2"
  if [[ -f "$PREFIX/config/$live" ]]; then
    quant_log "keeping existing $PREFIX/config/$live"
    return 0
  fi
  local src="$CONFIG_SRC/$example"
  [[ -f "$src" ]] || return 0
  if [[ "$DRY_RUN" == "1" ]]; then
    quant_log "DRY-RUN seed $live from $example"
    return 0
  fi
  quant_rewrite_config_paths "$src" "$PREFIX/config/$live" "$DATA_DIR"
  chmod 640 "$PREFIX/config/$live"
  quant_log "wrote $PREFIX/config/$live"
}

if has_component capture; then
  install_example tape-capture.example.toml
  seed_live_config tape-capture.example.toml tape-capture.toml
fi
if has_component sessionizer; then
  install_example tape-sessionizer.example.toml
  seed_live_config tape-sessionizer.example.toml tape-sessionizer.toml
fi
if has_component quant; then
  if [[ -f "$CONFIG_SRC/quant.example.yml" ]]; then
    install_example quant.example.yml
    if [[ ! -f "$PREFIX/config/quant.yml" ]]; then
      if [[ "$DRY_RUN" == "1" ]]; then
        quant_log "DRY-RUN seed quant.yml"
      else
        # Rewrite paths toward PREFIX
        sed \
          -e "s|data_dir:.*|data_dir: $DATA_DIR|" \
          -e "s|config: configs/tape-capture.toml|config: $PREFIX/config/tape-capture.toml|" \
          -e "s|config: configs/tape-sessionizer.toml|config: $PREFIX/config/tape-sessionizer.toml|" \
          -e "s|# bin: /opt/quant/bin/tape-capture|bin: $PREFIX/bin/tape-capture|" \
          -e "s|# bin: /opt/quant/bin/tape-sessionizer|bin: $PREFIX/bin/tape-sessionizer|" \
          "$CONFIG_SRC/quant.example.yml" >"$PREFIX/config/quant.yml"
        chmod 640 "$PREFIX/config/quant.yml"
        quant_log "wrote $PREFIX/config/quant.yml"
      fi
    else
      quant_log "keeping existing $PREFIX/config/quant.yml"
    fi
  fi
  quant_install_unit_templates "$TEMPLATE_SRC"
  quant_migrate_legacy_units
fi

if [[ "$DRY_RUN" != "1" ]]; then
  if [[ "$(id -u)" -eq 0 ]] && id -u quant >/dev/null 2>&1; then
    chown -R quant:quant "$PREFIX" "$DATA_DIR" 2>/dev/null || true
    chmod 750 "$PREFIX/config" 2>/dev/null || true
    chmod 640 "$PREFIX/config/"*.toml "$PREFIX/config/"*.yml 2>/dev/null || true
  fi
fi

quant_write_manifest "$PREFIX" "${VERSION_STR:-unknown}" "$CHANNEL" "$SOURCE" "$SOURCE_EXTRA" "${COMPONENTS[@]}"

if [[ "$UPGRADE" == "1" || "$RESTART_SESSIONIZER" == "1" ]]; then
  if has_component sessionizer && [[ "$RESTART_SESSIONIZER" == "1" ]]; then
    quant_restart_sessionizers
  fi
fi
if has_component capture && [[ "$RESTART_CAPTURE" == "1" ]]; then
  quant_restart_captures
fi

if [[ "$ENABLE" == "1" && -n "$COMPOSE_PATH" ]] && has_component quant; then
  QBIN="$PREFIX/bin/quant"
  if [[ -x "$QBIN" ]]; then
    quant_log "ENABLE=1 → $QBIN -f $COMPOSE_PATH up -d"
    if [[ "$DRY_RUN" != "1" ]]; then
      "$QBIN" -f "$COMPOSE_PATH" up -d || quant_log "warning: quant up -d failed"
    fi
  fi
fi

quant_log "done. version=${VERSION_STR:-unknown} → $PREFIX"
if has_component quant; then
  echo "Next: edit $PREFIX/config/quant.yml && $PREFIX/bin/quant -f $PREFIX/config/quant.yml up -d"
fi
