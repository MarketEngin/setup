#!/usr/bin/env bash
# MarketEngin setup — ask first, download apps only after confirm.
#
#   curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh | bash
#   curl -fsSL …/get.sh | bash -s -- --components all --channel stable --yes
#
# Never: curl … | sudo bash
#
set -euo pipefail

printf 'MarketEngin setup — starting…\n' >&2

: "${QUANT_SETUP_URL:=https://github.com/MarketEngin/setup}"
: "${QUANT_SETUP_REF:=main}"
: "${QUANT_GIT_URL:=https://github.com/MarketEngin/MarketEngin.git}"
: "${QUANT_GITHUB_TOKEN:=${GITHUB_TOKEN:-}}"

VERSION_UI="1.0"
SELF_RAW_URL="https://raw.githubusercontent.com/MarketEngin/setup/${QUANT_SETUP_REF}/get.sh"
SETUP_RAW_BASE="https://raw.githubusercontent.com/MarketEngin/setup/${QUANT_SETUP_REF}"

die_early() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ── sudo elevate (copy of THIS script only — not app binaries) ──────────────
if [[ "$(id -u)" -ne 0 ]]; then
  printf 'Need root — re-running with sudo.\n' >&2
  SRC=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    case "${BASH_SOURCE[0]}" in
      /dev/*) SRC="" ;;
      *) SRC="${BASH_SOURCE[0]}" ;;
    esac
  fi
  if [[ -z "$SRC" ]]; then
    printf 'Note: copying this setup script for sudo (NOT downloading your apps)…\n' >&2
    command -v curl >/dev/null 2>&1 || die_early "curl required"
    SRC="$(mktemp /tmp/marketengin-get.XXXXXX)"
    curl -fL --connect-timeout 5 --max-time 20 --retry 2 -o "$SRC" "$SELF_RAW_URL" \
      || die_early "could not copy get.sh. Try: curl -fsSL $SELF_RAW_URL -o /tmp/me-get.sh && sudo -E bash /tmp/me-get.sh"
    chmod 700 "$SRC"
  fi
  printf 'Enter sudo password if prompted…\n' >&2
  export QUANT_SETUP_URL QUANT_SETUP_REF QUANT_GIT_URL QUANT_GITHUB_TOKEN GITHUB_TOKEN
  exec sudo -E bash "$SRC" "$@"
fi

printf 'Running as root.\n' >&2

USE_COLOR=0
[[ -t 2 && -z "${NO_COLOR:-}" ]] && USE_COLOR=1
if [[ "$USE_COLOR" == "1" ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'; C_MAG=$'\033[35m'
else
  C_RESET= C_DIM= C_BOLD= C_CYAN= C_GREEN= C_YELLOW= C_RED= C_MAG=
fi

log()  { printf '%s%s%s %s\n' "$C_CYAN" "◆" "$C_RESET" "$*" >&2; }
ok()   { printf '%s%s%s %s\n' "$C_GREEN" "✓" "$C_RESET" "$*" >&2; }
warn() { printf '%s%s%s %s\n' "$C_YELLOW" "!" "$C_RESET" "$*" >&2; }
err()  { printf '%s%s%s %s\n' "$C_RED" "✗" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n%s[%s/%s]%s %s%s%s\n' "$C_DIM" "$1" "$2" "$C_RESET" "$C_BOLD" "$3" "$C_RESET" >&2; }

_tty_read() {
  local prompt="$1" var="$2" silent="${3:-}"
  if [[ -c /dev/tty ]]; then
    if [[ "$silent" == "1" ]]; then
      read -r -s -p "$prompt" "$var" < /dev/tty || true; echo >&2
    else
      read -r -p "$prompt" "$var" < /dev/tty || true
    fi
  else
    if [[ "$silent" == "1" ]]; then
      read -r -s -p "$prompt" "$var" || true; echo >&2
    else
      read -r -p "$prompt" "$var" || true
    fi
  fi
}

ask() {
  local prompt="$1" default="${2:-}" ans
  if [[ -n "$default" ]]; then
    _tty_read "$(printf '%s? %s[%s]%s: ' "$prompt" "$C_DIM" "$default" "$C_RESET")" ans
    echo "${ans:-$default}"
  else
    _tty_read "$(printf '%s: ' "$prompt")" ans
    echo "${ans:-}"
  fi
}
ask_secret() {
  local prompt="$1" ans
  _tty_read "$(printf '%s: ' "$prompt")" ans 1
  echo "${ans:-}"
}
confirm() {
  local prompt="$1" default="${2:-y}" ans hint="Y/n"
  [[ "$default" == "n" ]] && hint="y/N"
  _tty_read "$(printf '%s %s(%s)%s: ' "$prompt" "$C_DIM" "$hint" "$C_RESET")" ans
  ans="$(echo "${ans:-$default}" | tr '[:upper:]' '[:lower:]')"
  [[ "$ans" == "y" || "$ans" == "yes" ]]
}

banner() {
  cat >&2 <<EOF

${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════════════════╗
║   ${C_RESET}${C_BOLD}M A R K E T E N G I N${C_CYAN}   ·   setup ${VERSION_UI}              ║
║   ${C_DIM}ask first → then download only what you chose${C_CYAN}         ║
╚══════════════════════════════════════════════════════════╝${C_RESET}

EOF
}

usage() {
  cat <<'EOF'
MarketEngin setup

  curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh | bash

Flow: questions → plan (tags) → confirm → download each app with progress.

Options: --components LIST --channel stable|pre-release --upgrade --uninstall
         --prefix DIR --data-dir DIR --yes --dry-run -h
EOF
}

COMPONENTS_RAW=""
CHANNEL=""
MODE="install"
YES=0
DRY_RUN=0
PREFIX="${PREFIX:-/opt/quant}"
DATA_DIR="${DATA_DIR:-/var/lib/quant}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --components) COMPONENTS_RAW="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --upgrade) MODE="upgrade"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --data-dir) DATA_DIR="${2:-}"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

INTERACTIVE=1
[[ -n "$COMPONENTS_RAW" ]] && INTERACTIVE=0
HAVE_TTY=0
[[ -c /dev/tty ]] && HAVE_TTY=1
if [[ "$HAVE_TTY" != "1" ]]; then
  INTERACTIVE=0
  [[ -n "$COMPONENTS_RAW" || "$MODE" == "uninstall" ]] \
    || die "no TTY: pass --components LIST|all --yes"
fi

command -v curl >/dev/null 2>&1 || die "curl required"
command -v tar >/dev/null 2>&1 || die "tar required"
command -v git >/dev/null 2>&1 || die "git required (lists release tags)"

banner

# ── questions ONLY (no app / toolkit downloads yet) ─────────────────────────
if [[ "$INTERACTIVE" == "1" ]]; then
  TOTAL=5
  step 1 "$TOTAL" "What do you want to do?"
  echo "  ${C_BOLD}[1]${C_RESET} Install" >&2
  echo "  ${C_BOLD}[2]${C_RESET} Upgrade   ${C_DIM}(only newer tags per app)${C_RESET}" >&2
  echo "  ${C_BOLD}[3]${C_RESET} Uninstall" >&2
  case "$(ask "Choice" "1")" in
    2) MODE="upgrade" ;;
    3) MODE="uninstall" ;;
    *) MODE="install" ;;
  esac
  ok "mode → $MODE"

  if [[ "$MODE" != "uninstall" ]]; then
    step 2 "$TOTAL" "Release channel"
    echo "  ${C_BOLD}[1]${C_RESET} stable       ${C_DIM}{app}-vX.Y.Z${C_RESET}" >&2
    echo "  ${C_BOLD}[2]${C_RESET} pre-release  ${C_DIM}{app}-vX.Y.Z-devN${C_RESET}" >&2
    case "$(ask "Choice" "1")" in
      2) CHANNEL="pre-release" ;;
      *) CHANNEL="stable" ;;
    esac
    ok "channel → $CHANNEL"

    step 3 "$TOTAL" "Which apps?"
    echo "  ${C_BOLD}[1]${C_RESET} capture   ${C_DIM}tape-capture${C_RESET}" >&2
    echo "  ${C_BOLD}[2]${C_RESET} sessionizer" >&2
    echo "  ${C_BOLD}[3]${C_RESET} quant" >&2
    echo "  ${C_BOLD}[4]${C_RESET} lens" >&2
    echo "  ${C_BOLD}[5]${C_RESET} verify" >&2
    echo "  ${C_BOLD}[a]${C_RESET} all" >&2
    sel="$(echo "$(ask "Select" "a")" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    COMPS=()
    if [[ "$sel" == "a" || "$sel" == "all" ]]; then
      COMPS=(capture sessionizer quant lens verify)
    else
      map=(capture sessionizer quant lens verify)
      IFS=',' read -r -a parts <<<"$sel"
      for p in "${parts[@]}"; do
        [[ "$p" =~ ^[1-5]$ ]] || die "invalid: $p"
        COMPS+=("${map[$((p - 1))]}")
      done
    fi
    [[ ${#COMPS[@]} -gt 0 ]] || die "nothing selected"
    COMPONENTS_RAW="$(printf '%s\n' "${COMPS[@]}" | awk 'NF && !seen[$0]++ { printf "%s%s", (n++?",":""), $0 } END{print ""}')"
    ok "apps → $COMPONENTS_RAW"
  else
    CHANNEL="${CHANNEL:-stable}"
    sel="$(ask "Components to remove (blank = interactive picker)" "")"
    [[ -n "$sel" ]] && COMPONENTS_RAW="$sel"
  fi

  step 4 "$TOTAL" "GitHub token (optional)"
  if [[ -n "${QUANT_GITHUB_TOKEN:-}" ]]; then
    ok "token already in environment"
  else
    echo "  ${C_DIM}Needed if MarketEngin/MarketEngin is private. Leave blank if public.${C_RESET}" >&2
    tok="$(ask_secret "Token")"
    if [[ -n "$tok" ]]; then
      QUANT_GITHUB_TOKEN="$tok"
      export QUANT_GITHUB_TOKEN GITHUB_TOKEN="$tok"
      ok "token set for this session"
    else
      warn "no token"
    fi
  fi

  step 5 "$TOTAL" "Install paths"
  PREFIX="$(ask "Prefix" "$PREFIX")"
  DATA_DIR="$(ask "Data dir" "$DATA_DIR")"
  ok "prefix=$PREFIX data=$DATA_DIR"
else
  CHANNEL="${CHANNEL:-stable}"
  [[ -n "$COMPONENTS_RAW" || "$MODE" == "uninstall" ]] || die "--components required"
fi

export QUANT_GIT_URL QUANT_GITHUB_TOKEN GITHUB_TOKEN="${QUANT_GITHUB_TOKEN:-}"
export PREFIX DATA_DIR

# ── load installer helpers (scripts only — after you chose apps) ────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
SETUP_ROOT=""
LIB=""
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/lib.sh" ]]; then
  SETUP_ROOT="$SCRIPT_DIR"
  LIB="$SCRIPT_DIR/lib.sh"
else
  log "Loading installer helpers (lib.sh + systemd templates — not app binaries)…"
  SETUP_ROOT="$(mktemp -d /tmp/marketengin-toolkit.XXXXXX)"
  mkdir -p "$SETUP_ROOT/systemd"
  curl -fsSL --connect-timeout 5 --max-time 30 \
    -o "$SETUP_ROOT/lib.sh" "${SETUP_RAW_BASE}/lib.sh" \
    || die "failed to fetch lib.sh"
  for f in quant-tape-capture@.service quant-tape-session@.service quant-tape@.target; do
    curl -fsSL --connect-timeout 5 --max-time 30 \
      -o "$SETUP_ROOT/systemd/$f" "${SETUP_RAW_BASE}/systemd/$f" \
      || die "failed to fetch systemd/$f"
  done
  # uninstall helper optional
  curl -fsSL --connect-timeout 5 --max-time 30 \
    -o "$SETUP_ROOT/uninstall.sh" "${SETUP_RAW_BASE}/uninstall.sh" 2>/dev/null || true
  chmod +x "$SETUP_ROOT"/*.sh 2>/dev/null || true
  LIB="$SETUP_ROOT/lib.sh"
  ok "helpers ready"
fi
# shellcheck source=lib.sh
source "$LIB"

if [[ "$MODE" == "uninstall" ]]; then
  args=()
  [[ -n "$COMPONENTS_RAW" ]] && args+=(--components "$COMPONENTS_RAW")
  log "Starting uninstall…"
  exec "$SETUP_ROOT/uninstall.sh" "${args[@]}"
fi

CHANNEL="$(quant_normalize_channel "$CHANNEL")"
COMPONENTS=()
while IFS= read -r _c; do
  [[ -n "$_c" ]] && COMPONENTS+=("$_c")
done < <(quant_parse_components "$COMPONENTS_RAW")
[[ ${#COMPONENTS[@]} -gt 0 ]] || die "no components"

UPGRADE_FLAG=0
[[ "$MODE" == "upgrade" ]] && UPGRADE_FLAG=1

# ── plan preview (metadata only: git ls-remote) ─────────────────────────────
log "Resolving latest tags on $CHANNEL (metadata only)…"
TAGS="$(quant_list_remote_tags "$QUANT_GIT_URL")" \
  || die "could not list tags from $QUANT_GIT_URL"

PLAN_LINES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && PLAN_LINES+=("$line")
done < <(quant_emit_install_plan "$CHANNEL" "$UPGRADE_FLAG" "$PREFIX" "$TAGS" "${COMPONENTS[@]}")

echo >&2
printf '%s──────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET" >&2
printf '%s Plan%s  mode=%s  channel=%s\n' "$C_BOLD" "$C_RESET" "$MODE" "$CHANNEL" >&2
NEED_WORK=0
for line in "${PLAN_LINES[@]}"; do
  IFS='|' read -r c action installed latest <<<"$line"
  bin="$(quant_bin_for_component "$c")"
  case "$action" in
    skip)
      printf '  %s%-12s%s  skip (already %s)\n' "$C_DIM" "$bin" "$C_RESET" "$installed" >&2
      ;;
    upgrade)
      printf '  %s%-12s%s  %supgrade%s  %s → %s\n' "$C_BOLD" "$bin" "$C_RESET" "$C_YELLOW" "$C_RESET" "$installed" "$latest" >&2
      NEED_WORK=1
      ;;
    install)
      printf '  %s%-12s%s  %sinstall%s  %s\n' "$C_BOLD" "$bin" "$C_RESET" "$C_GREEN" "$C_RESET" "$latest" >&2
      NEED_WORK=1
      ;;
  esac
done
printf '%s──────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET" >&2

if [[ "$NEED_WORK" -eq 0 ]]; then
  ok "Nothing to download — everything is up to date."
  exit 0
fi

if [[ "$YES" != "1" ]]; then
  confirm "Download and install the planned apps now" y || die "aborted"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  ok "DRY-RUN — no downloads performed"
  exit 0
fi

# ── download + install each app (with progress) ─────────────────────────────
WORKDIR="$(mktemp -d /tmp/quant-install.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

quant_ensure_user_and_dirs "$PREFIX" "$DATA_DIR"

TO_DO=()
for line in "${PLAN_LINES[@]}"; do
  IFS='|' read -r c action _ latest <<<"$line"
  [[ "$action" == "skip" ]] && continue
  TO_DO+=("$c|$latest")
done

TOTAL="${#TO_DO[@]}"
IDX=0
COMPONENT_SPECS=()
for line in "${PLAN_LINES[@]}"; do
  IFS='|' read -r c action installed latest <<<"$line"
  if [[ "$action" == "skip" ]]; then
    COMPONENT_SPECS+=("${c}=${installed}")
    continue
  fi
  IDX=$((IDX + 1))
  quant_install_one_component_narrated "$IDX" "$TOTAL" "$c" "$latest" "$PREFIX" "$WORKDIR"
  COMPONENT_SPECS+=("${c}=${latest}")
done

# systemd templates if quant selected
has_quant=0
for c in "${COMPONENTS[@]}"; do
  [[ "$c" == "quant" ]] && has_quant=1
done
if [[ "$has_quant" == "1" ]]; then
  log "Installing systemd unit templates…"
  quant_install_unit_templates "$SETUP_ROOT/systemd"
  quant_migrate_legacy_units
fi

VERSION_STR="$(printf '%s\n' "${COMPONENT_SPECS[@]}" | sed 's/^[^=]*=//' | awk 'NF{printf "%s%s", (n++?",":""), $0} END{print ""}')"
[[ -n "$VERSION_STR" ]] || VERSION_STR="ok"
quant_write_manifest "$PREFIX" "$VERSION_STR" "$CHANNEL" "git" "$QUANT_GIT_URL#$CHANNEL" \
  "${COMPONENT_SPECS[@]}"

if [[ "$(id -u)" -eq 0 ]] && id -u quant >/dev/null 2>&1; then
  chown -R quant:quant "$PREFIX" "$DATA_DIR" 2>/dev/null || true
fi

if [[ "$UPGRADE_FLAG" == "1" ]]; then
  for c in "${COMPONENTS[@]}"; do
    [[ "$c" == "sessionizer" ]] && quant_restart_sessionizers
  done
fi

ok "All done."
echo "Binaries: $PREFIX/bin" >&2
