#!/usr/bin/env bash
# MarketEngin setup — interactive bootstrap.
#
# CORRECT (script elevates itself — do NOT pipe into sudo):
#   curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh | bash
#
# Non-interactive:
#   curl -fsSL …/get.sh | bash -s -- --components all --channel stable --yes
#
set -euo pipefail

# Immediate feedback (before anything that can hang).
printf 'MarketEngin setup — starting…\n' >&2

: "${QUANT_SETUP_URL:=https://github.com/MarketEngin/setup}"
: "${QUANT_SETUP_REF:=main}"
: "${QUANT_GIT_URL:=https://github.com/MarketEngin/MarketEngin.git}"
: "${QUANT_GITHUB_TOKEN:=${GITHUB_TOKEN:-}}"

VERSION_UI="1.0"
SELF_RAW_URL="https://raw.githubusercontent.com/MarketEngin/setup/${QUANT_SETUP_REF}/get.sh"

# ── self-elevate (never: curl | sudo bash — sudo steals the pipe as password) ─
if [[ "$(uname -s)" == "Linux" && "$(id -u)" -ne 0 ]]; then
  printf 'Need root privileges. Re-running with sudo (password prompt on your terminal)…\n' >&2
  TMP_SELF="$(mktemp /tmp/marketengin-get.XXXXXX)"
  # Prefer re-download to a file so sudo has a real path (stdin is the script pipe).
  if command -v curl >/dev/null 2>&1 && curl -fsSL --connect-timeout 15 --max-time 120 \
      "$SELF_RAW_URL" -o "$TMP_SELF"; then
    chmod 700 "$TMP_SELF"
    export QUANT_SETUP_URL QUANT_SETUP_REF QUANT_GIT_URL QUANT_GITHUB_TOKEN GITHUB_TOKEN
    exec sudo -E bash "$TMP_SELF" "$@"
  fi
  # Fallback: copy from BASH_SOURCE if we were invoked as a file
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" && "${BASH_SOURCE[0]}" != "bash" ]]; then
    exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
  fi
  printf 'ERROR: could not re-download get.sh for sudo. Try:\n' >&2
  printf '  curl -fsSL %s -o /tmp/me-get.sh && sudo -E bash /tmp/me-get.sh\n' "$SELF_RAW_URL" >&2
  exit 1
fi

# Warn if someone still used curl|sudo bash (stdin is pipe, no tty for wizard).
if [[ -p /dev/stdin ]] || [[ ! -t 0 && ! -c /dev/tty ]]; then
  :
fi

# Attach interactive stdin from the real terminal when piped.
{ [[ -c /dev/tty ]] && exec </dev/tty; } 2>/dev/null || true

USE_COLOR=0
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  USE_COLOR=1
fi
if [[ "$USE_COLOR" == "1" ]]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_MAG=$'\033[35m'
else
  C_RESET= C_DIM= C_BOLD= C_CYAN= C_GREEN= C_YELLOW= C_RED= C_MAG=
fi

log()  { printf '%s%s%s %s\n' "$C_CYAN" "◆" "$C_RESET" "$*" >&2; }
ok()   { printf '%s%s%s %s\n' "$C_GREEN" "✓" "$C_RESET" "$*" >&2; }
warn() { printf '%s%s%s %s\n' "$C_YELLOW" "!" "$C_RESET" "$*" >&2; }
err()  { printf '%s%s%s %s\n' "$C_RED" "✗" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n%s[%s/%s]%s %s%s%s\n' "$C_DIM" "$1" "$2" "$C_RESET" "$C_BOLD" "$3" "$C_RESET" >&2; }

ask() {
  local prompt="$1" default="${2:-}" ans
  if [[ -n "$default" ]]; then
    read -r -p "$(printf '%s? %s[%s]%s: ' "$prompt" "$C_DIM" "$default" "$C_RESET")" ans || true
    echo "${ans:-$default}"
  else
    read -r -p "$(printf '%s: ' "$prompt")" ans || true
    echo "${ans:-}"
  fi
}

ask_secret() {
  local prompt="$1" ans
  read -r -s -p "$(printf '%s: ' "$prompt")" ans || true
  echo >&2
  echo "${ans:-}"
}

confirm() {
  local prompt="$1" default="${2:-y}" ans hint="Y/n"
  [[ "$default" == "n" ]] && hint="y/N"
  read -r -p "$(printf '%s %s(%s)%s: ' "$prompt" "$C_DIM" "$hint" "$C_RESET")" ans || true
  ans="$(echo "${ans:-$default}" | tr '[:upper:]' '[:lower:]')"
  [[ "$ans" == "y" || "$ans" == "yes" ]]
}

banner() {
  cat >&2 <<EOF

${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════════════════╗
║                                                          ║
║   ${C_RESET}${C_BOLD}M A R K E T E N G I N${C_CYAN}   ·   setup ${VERSION_UI}              ║
║   ${C_DIM}tape stack installer · capture · session · tools${C_CYAN}       ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝${C_RESET}

${C_DIM}installer${C_RESET}  ${QUANT_SETUP_URL}@${QUANT_SETUP_REF}
${C_DIM}releases${C_RESET}   ${QUANT_GIT_URL}

EOF
}

usage() {
  cat <<'EOF'
MarketEngin setup (get.sh)

Usage (do NOT pipe into sudo — the script elevates itself):
  curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh | bash

  curl -fsSL …/get.sh | bash -s -- --components all --channel stable --yes

  # Alternative if pipe is awkward:
  curl -fsSL …/get.sh -o /tmp/me-get.sh && sudo -E bash /tmp/me-get.sh

Options:
  --components LIST   capture,sessionizer,quant,lens,verify or all
  --channel NAME      stable | pre-release
  --upgrade           only install newer tags
  --uninstall         run uninstall instead of install
  --prefix DIR        install prefix (default /opt/quant)
  --data-dir DIR
  --yes               skip final confirmation
  --dry-run
  -h, --help

Env: QUANT_GITHUB_TOKEN QUANT_GIT_URL QUANT_SETUP_URL QUANT_SETUP_REF
EOF
}

COMPONENTS_RAW=""
CHANNEL=""
MODE="install"
YES=0
DRY_RUN=0
PREFIX="${PREFIX:-/opt/quant}"
DATA_DIR="${DATA_DIR:-/var/lib/quant}"
EXTRA_INSTALL_ARGS=()

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
    *) EXTRA_INSTALL_ARGS+=("$1"); shift ;;
  esac
done

INTERACTIVE=1
[[ -n "$COMPONENTS_RAW" ]] && INTERACTIVE=0

HAVE_TTY=0
if [[ -t 0 ]] || [[ -c /dev/tty ]]; then
  HAVE_TTY=1
fi
if [[ "$HAVE_TTY" != "1" ]]; then
  INTERACTIVE=0
  if [[ -z "$COMPONENTS_RAW" && "$MODE" != "uninstall" ]]; then
    die "no terminal for prompts. Use:  curl …/get.sh | bash -s -- --components all --yes"
  fi
fi

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

banner

if [[ "$INTERACTIVE" == "1" ]]; then
  TOTAL=5
  step 1 "$TOTAL" "What do you want to do?"
  echo "  ${C_BOLD}[1]${C_RESET} Install     — download latest release binaries" >&2
  echo "  ${C_BOLD}[2]${C_RESET} Upgrade     — only components with a newer tag" >&2
  echo "  ${C_BOLD}[3]${C_RESET} Uninstall   — remove selected installed apps" >&2
  choice="$(ask "Choice" "1")"
  case "$choice" in
    2) MODE="upgrade" ;;
    3) MODE="uninstall" ;;
    *) MODE="install" ;;
  esac
  ok "mode → $MODE"

  if [[ "$MODE" != "uninstall" ]]; then
    step 2 "$TOTAL" "Release channel"
    echo "  ${C_BOLD}[1]${C_RESET} stable       ${C_DIM}{app}-vX.Y.Z${C_RESET}" >&2
    echo "  ${C_BOLD}[2]${C_RESET} pre-release  ${C_DIM}{app}-vX.Y.Z-devN${C_RESET}" >&2
    choice="$(ask "Choice" "1")"
    case "$choice" in
      2) CHANNEL="pre-release" ;;
      *) CHANNEL="stable" ;;
    esac
    ok "channel → $CHANNEL"

    step 3 "$TOTAL" "Components to ${MODE}"
    echo "  ${C_DIM}Numbers, comma-separated — or ${C_RESET}${C_BOLD}a${C_RESET}${C_DIM} for all${C_RESET}" >&2
    echo "  ${C_BOLD}[1]${C_RESET} capture      ${C_DIM}tape-capture${C_RESET}" >&2
    echo "  ${C_BOLD}[2]${C_RESET} sessionizer  ${C_DIM}tape-sessionizer${C_RESET}" >&2
    echo "  ${C_BOLD}[3]${C_RESET} quant        ${C_DIM}orchestrator + systemd templates${C_RESET}" >&2
    echo "  ${C_BOLD}[4]${C_RESET} lens         ${C_DIM}tape-lens${C_RESET}" >&2
    echo "  ${C_BOLD}[5]${C_RESET} verify       ${C_DIM}tape-verify${C_RESET}" >&2
    echo "  ${C_BOLD}[a]${C_RESET} all" >&2
    sel="$(ask "Select" "a")"
    sel="$(echo "$sel" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    COMPS=()
    if [[ "$sel" == "a" || "$sel" == "all" ]]; then
      COMPS=(capture sessionizer quant lens verify)
    else
      map=(capture sessionizer quant lens verify)
      IFS=',' read -r -a parts <<<"$sel"
      for p in "${parts[@]}"; do
        [[ "$p" =~ ^[1-5]$ ]] || die "invalid selection: $p"
        COMPS+=("${map[$((p - 1))]}")
      done
    fi
    [[ ${#COMPS[@]} -gt 0 ]] || die "nothing selected"
    COMPONENTS_RAW="$(printf '%s\n' "${COMPS[@]}" | awk 'NF && !seen[$0]++ { printf "%s%s", (n++?",":""), $0 } END{print ""}')"
    ok "components → $COMPONENTS_RAW"
  else
    step 2 "$TOTAL" "Uninstall"
    echo "  Leave blank for interactive picker after bootstrap." >&2
    sel="$(ask "Components (or blank)" "")"
    [[ -n "$sel" ]] && COMPONENTS_RAW="$sel"
    CHANNEL="${CHANNEL:-stable}"
  fi

  step 4 "$TOTAL" "GitHub access"
  echo "  Releases from ${C_BOLD}MarketEngin/MarketEngin${C_RESET}." >&2
  echo "  ${C_DIM}Private → PAT (Contents read). Blank if public.${C_RESET}" >&2
  if [[ -n "${QUANT_GITHUB_TOKEN:-}" ]]; then
    ok "token already set in environment"
  else
    tok="$(ask_secret "GitHub token (optional)")"
    if [[ -n "$tok" ]]; then
      QUANT_GITHUB_TOKEN="$tok"
      export QUANT_GITHUB_TOKEN GITHUB_TOKEN="$tok"
      ok "token captured for this session"
    else
      warn "no token — public access only"
    fi
  fi

  step 5 "$TOTAL" "Paths"
  PREFIX="$(ask "Install prefix" "$PREFIX")"
  DATA_DIR="$(ask "Data directory" "$DATA_DIR")"
  ok "prefix=$PREFIX  data=$DATA_DIR"
else
  CHANNEL="${CHANNEL:-stable}"
  [[ -n "$COMPONENTS_RAW" || "$MODE" == "uninstall" ]] || die "--components required"
fi

echo >&2
printf '%s──────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET" >&2
printf '%s Summary%s\n' "$C_BOLD" "$C_RESET" >&2
printf '  mode        %s%s%s\n' "$C_MAG" "$MODE" "$C_RESET" >&2
[[ "$MODE" != "uninstall" ]] && printf '  channel     %s\n' "$CHANNEL" >&2
printf '  components  %s\n' "${COMPONENTS_RAW:-"(interactive uninstall)"}" >&2
printf '  prefix      %s\n' "$PREFIX" >&2
printf '  data        %s\n' "$DATA_DIR" >&2
printf '  token       %s\n' "$([[ -n "${QUANT_GITHUB_TOKEN:-}" ]] && echo yes || echo no)" >&2
printf '%s──────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET" >&2

if [[ "$YES" != "1" ]]; then
  confirm "Proceed" y || die "aborted"
fi

# ── fetch installer tree ────────────────────────────────────────────────────
owner_repo=""
if [[ "$QUANT_SETUP_URL" =~ github\.com[:/]+([^/]+)/([^/.]+)(\.git)?/?$ ]]; then
  owner_repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
else
  die "QUANT_SETUP_URL must be a github.com URL"
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

ARCHIVE_URL="https://codeload.github.com/${owner_repo}/tar.gz/refs/heads/${QUANT_SETUP_REF}"
log "downloading installer ${owner_repo}@${QUANT_SETUP_REF} …"
# --progress-bar on stderr so the user sees activity
if ! curl -fL --connect-timeout 15 --max-time 180 --progress-bar \
    "${HDR[@]}" -o "$ARCHIVE" "$ARCHIVE_URL"; then
  die "failed to download $ARCHIVE_URL"
fi
ok "download complete ($(wc -c <"$ARCHIVE" | tr -d ' ') bytes)"

tar -xzf "$ARCHIVE" -C "$EXTRACT"
ROOT="$(find "$EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -n "$ROOT" && -f "$ROOT/install.sh" && -f "$ROOT/lib.sh" ]] \
  || die "installer archive incomplete"
chmod +x "$ROOT"/*.sh 2>/dev/null || true
ok "installer ready"

export QUANT_GIT_URL QUANT_GITHUB_TOKEN QUANT_SETUP_URL QUANT_SETUP_REF
export PREFIX DATA_DIR GITHUB_TOKEN="${QUANT_GITHUB_TOKEN:-}"

if [[ "$MODE" == "uninstall" ]]; then
  args=()
  [[ -n "$COMPONENTS_RAW" ]] && args+=(--components "$COMPONENTS_RAW")
  log "starting uninstall…"
  exec "$ROOT/uninstall.sh" "${args[@]}"
fi

args=(--channel "$CHANNEL" --components "$COMPONENTS_RAW")
[[ "$MODE" == "upgrade" ]] && args+=(--upgrade)
[[ "$DRY_RUN" == "1" ]] && args+=(--dry-run)
if [[ ${#EXTRA_INSTALL_ARGS[@]} -gt 0 ]]; then
  args+=("${EXTRA_INSTALL_ARGS[@]}")
fi

log "starting ${MODE}…"
exec env PREFIX="$PREFIX" DATA_DIR="$DATA_DIR" "$ROOT/install.sh" "${args[@]}"
