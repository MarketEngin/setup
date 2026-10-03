#!/usr/bin/env bash
# Non-interactive / CI installer (shares lib.sh with get.sh).
#
# Interactive: curl -fsSL …/get.sh | bash
# Never: curl … | sudo bash
#
# Per-app GitHub Releases on MarketEngin/MarketEngin:
#   tag   {bin}-vX.Y.Z  |  {bin}-vX.Y.Z-devN
#   asset {bin}-linux-amd64.tar.gz
#
#   sudo ./install.sh --components all
#   sudo ./install.sh --channel pre-release --components all
#   sudo ./install.sh --upgrade --channel stable --components sessionizer,quant
#   sudo ./install.sh --reinstall --components all
#   sudo ./install.sh --source local --bin-src ./target/release --components quant,lens
#
# Env: PREFIX DATA_DIR
#      QUANT_GIT_URL=https://github.com/MarketEngin/MarketEngin.git
#      QUANT_SETUP_URL=https://github.com/MarketEngin/setup
#      QUANT_GITHUB_TOKEN|GITHUB_TOKEN
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
REINSTALL=0
MODE="install"
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
  --url URL           single archive URL (implies --source url)
  --upgrade           per-component: install only if newer tag on channel
  --reinstall         force re-download/install even if tag matches
  --restart-sessionizer / --no-restart-sessionizer
  --restart-capture
  --compose PATH      with ENABLE=1, run: quant -f PATH up -d
  --dry-run
  -h, --help

  git mode downloads each component's GitHub Release asset
  ({bin}-linux-amd64.tar.gz) for the latest {bin}-v… tag on the channel.
  Binaries are linked into /usr/local/bin so `quant` works on PATH.

Env: PREFIX=/opt/quant DATA_DIR=/var/lib/quant
     QUANT_GIT_URL=https://github.com/MarketEngin/MarketEngin.git
     QUANT_GITHUB_TOKEN|GITHUB_TOKEN  (private: Contents + Releases read)
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
    --upgrade) UPGRADE=1; MODE="upgrade"; shift ;;
    --reinstall) REINSTALL=1; MODE="reinstall"; shift ;;
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

if [[ "$REINSTALL" == "1" && "$UPGRADE" == "1" ]]; then
  quant_die "use either --upgrade or --reinstall, not both"
fi
if [[ "$REINSTALL" == "1" ]]; then
  MODE="reinstall"
elif [[ "$UPGRADE" == "1" ]]; then
  MODE="upgrade"
else
  MODE="install"
fi

quant_log "prefix=$PREFIX data=$DATA_DIR source=$SOURCE channel=$CHANNEL mode=$MODE"
quant_log "components: ${COMPONENTS[*]}"

NEED_ROOT=0
if [[ "$(uname -s)" == "Linux" ]] && [[ "$DRY_RUN" != "1" ]]; then
  NEED_ROOT=1
fi
# Installing into /opt typically needs root; allow dry-run / non-root PREFIX elsewhere
if [[ "$NEED_ROOT" == "1" && "$(id -u)" -ne 0 && "$PREFIX" == /opt/* ]]; then
  quant_die "run as root (sudo) to install under $PREFIX"
fi

CONFIG_SRC="$SCRIPT_DIR/configs"
TEMPLATE_SRC="$SCRIPT_DIR/systemd"
[[ -f "$TEMPLATE_SRC/quant-tape@.target" ]] \
  || quant_die "missing unit templates in $TEMPLATE_SRC"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/quant-install.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

STAGE_BIN="$WORKDIR/stage/bin"
mkdir -p "$STAGE_BIN"

VERSION_STR=""
SOURCE_EXTRA=""
# Populated as "comp=tag" for manifest
COMPONENT_SPECS=()
# Set when resolve_git already placed binaries into PREFIX (skip STAGE_BIN loop)
GIT_BINS_PLACED=0

resolve_git() {
  quant_log "listing tags from $QUANT_GIT_URL"
  local tags
  tags="$(quant_list_remote_tags "$QUANT_GIT_URL")" \
    || quant_die "failed to list tags from $QUANT_GIT_URL"

  local -a plan_lines=()
  local line c action installed latest
  while IFS= read -r line; do
    [[ -n "$line" ]] && plan_lines+=("$line")
  done < <(quant_emit_install_plan "$CHANNEL" "$MODE" "$PREFIX" "$tags" "${COMPONENTS[@]}")

  local -a to_install=()
  local -a plan_tags=()
  for line in "${plan_lines[@]}"; do
    IFS='|' read -r c action installed latest <<<"$line"
    case "$action" in
      skip)
        quant_log "$c: already up to date ($installed)"
        COMPONENT_SPECS+=("${c}=${installed}")
        ;;
      upgrade)
        quant_log "$c: upgrade $installed → $latest"
        to_install+=("$c")
        plan_tags+=("$latest")
        COMPONENT_SPECS+=("${c}=${latest}")
        ;;
      reinstall)
        quant_log "$c: reinstall $installed → $latest"
        to_install+=("$c")
        plan_tags+=("$latest")
        COMPONENT_SPECS+=("${c}=${latest}")
        ;;
      install)
        quant_log "$c: will install $latest"
        to_install+=("$c")
        plan_tags+=("$latest")
        COMPONENT_SPECS+=("${c}=${latest}")
        ;;
    esac
  done

  if [[ ${#to_install[@]} -eq 0 ]]; then
    quant_log "No newer $CHANNEL versions for selected components"
    VERSION_STR="$(quant_read_installed_version "$PREFIX" 2>/dev/null || echo up-to-date)"
    SOURCE_EXTRA="noop@$CHANNEL"
    GIT_BINS_PLACED=1
    return 0
  fi

  VERSION_STR="$(IFS=','; echo "${plan_tags[*]}")"
  SOURCE_EXTRA="$QUANT_GIT_URL#$CHANNEL"

  if [[ "$DRY_RUN" == "1" ]]; then
    quant_log "DRY-RUN would fetch: ${plan_tags[*]}"
    return 0
  fi

  local i=0 total="${#to_install[@]}"
  for c in "${to_install[@]}"; do
    latest="${plan_tags[$i]}"
    i=$((i + 1))
    quant_install_one_component_narrated "$i" "$total" "$c" "$latest" "$PREFIX" "$WORKDIR"
  done
  GIT_BINS_PLACED=1
}

resolve_local() {
  local dir="${BIN_SRC_OPT:-${BIN_SRC:-}}"
  [[ -n "$dir" ]] || quant_die "--bin-src or BIN_SRC required for --source local"
  [[ -d "$dir" ]] || quant_die "bin-src not a directory: $dir"
  VERSION_STR="local"
  if [[ -f "$dir/VERSION" ]]; then
    VERSION_STR="$(tr -d '[:space:]' <"$dir/VERSION")"
  elif [[ -f "$PREFIX/VERSION" && "$UPGRADE" != "1" ]]; then
    :
  fi
  SOURCE_EXTRA="$dir"
  quant_stage_bins_from_dir "$dir" "$STAGE_BIN" "${COMPONENTS[@]}"
  local c
  for c in "${COMPONENTS[@]}"; do
    COMPONENT_SPECS+=("${c}=${VERSION_STR}")
  done
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
  local c
  for c in "${COMPONENTS[@]}"; do
    COMPONENT_SPECS+=("${c}=${VERSION_STR}")
  done
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

if [[ "$GIT_BINS_PLACED" == "1" ]]; then
  # ensure PATH links for skipped (already current) components too
  for local_c in "${COMPONENTS[@]}"; do
    bin="$(quant_bin_for_component "$local_c")"
    [[ -x "$PREFIX/bin/$bin" ]] && quant_link_bin "$PREFIX/bin/$bin"
  done
elif [[ "$DRY_RUN" != "1" || -d "$STAGE_BIN" ]]; then
  local_c=""
  for local_c in "${COMPONENTS[@]}"; do
    bin="$(quant_bin_for_component "$local_c")"
    if [[ -f "$STAGE_BIN/$bin" ]]; then
      quant_atomic_install_bin "$STAGE_BIN/$bin" "$PREFIX/bin/$bin"
      quant_link_bin "$PREFIX/bin/$bin"
      quant_log "installed $PREFIX/bin/$bin"
    elif [[ "$DRY_RUN" == "1" ]]; then
      quant_log "DRY-RUN would install $bin"
    elif [[ "$UPGRADE" == "1" && -f "$PREFIX/bin/$bin" ]]; then
      quant_log "kept existing $PREFIX/bin/$bin"
      quant_link_bin "$PREFIX/bin/$bin"
    else
      quant_die "staged binary missing: $STAGE_BIN/$bin"
    fi
  done
fi

quant_ensure_path_profile "$PREFIX"

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

if [[ ${#COMPONENT_SPECS[@]} -eq 0 ]]; then
  for local_c in "${COMPONENTS[@]}"; do
    COMPONENT_SPECS+=("${local_c}=${VERSION_STR:-unknown}")
  done
fi
quant_write_manifest "$PREFIX" "${VERSION_STR:-unknown}" "$CHANNEL" "$SOURCE" "$SOURCE_EXTRA" \
  "${COMPONENT_SPECS[@]}"

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
quant_print_bin_howto "$PREFIX" "${COMPONENTS[@]}"
if has_component quant; then
  echo "Next: edit $PREFIX/config/quant.yml && quant -f $PREFIX/config/quant.yml up -d" >&2
fi
