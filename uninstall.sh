#!/usr/bin/env bash
# Component-aware uninstall for quant stack.
#
# Interactive (TTY): lists installed packages and asks which to remove.
# Non-interactive: require --components LIST|all
#
#   sudo ./deploy/uninstall.sh
#   sudo ./deploy/uninstall.sh --components lens,verify
#   sudo REMOVE_DATA=1 REMOVE_CONFIG=1 ./deploy/uninstall.sh --components all

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PREFIX="${PREFIX:-/opt/quant}"
DATA_DIR="${DATA_DIR:-/var/lib/quant}"
REMOVE_DATA="${REMOVE_DATA:-}"
REMOVE_CONFIG="${REMOVE_CONFIG:-}"
COMPONENTS_RAW=""

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--components LIST|all]

  With a TTY and no --components: prompt which installed apps to remove.
  Non-TTY: --components is required.

Env: PREFIX DATA_DIR REMOVE_DATA=0|1 REMOVE_CONFIG=0|1
     (if unset on TTY, you will be asked about config/data)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --components) COMPONENTS_RAW="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) quant_die "unknown arg: $1" ;;
  esac
done

if [[ "$(uname -s)" == "Linux" && "$(id -u)" -ne 0 && "$PREFIX" == /opt/* ]]; then
  quant_die "run as root (sudo) to uninstall under $PREFIX"
fi

INSTALLED=()
while IFS= read -r _c; do
  [[ -n "$_c" ]] && INSTALLED+=("$_c")
done < <(quant_installed_components "$PREFIX")

if [[ ${#INSTALLED[@]} -eq 0 ]]; then
  quant_die "nothing installed under $PREFIX/bin"
fi

COMPONENTS=()
if [[ -n "$COMPONENTS_RAW" ]]; then
  while IFS= read -r _c; do
    [[ -n "$_c" ]] && COMPONENTS+=("$_c")
  done < <(quant_parse_components "$COMPONENTS_RAW")
  # Only remove ones that are actually installed
  local_filtered=()
  for _c in "${COMPONENTS[@]}"; do
    for _i in "${INSTALLED[@]}"; do
      if [[ "$_c" == "$_i" ]]; then
        local_filtered+=("$_c")
        break
      fi
    done
  done
  COMPONENTS=("${local_filtered[@]}")
  [[ ${#COMPONENTS[@]} -gt 0 ]] || quant_die "none of the requested components are installed (have: ${INSTALLED[*]})"
else
  while IFS= read -r _c; do
    [[ -n "$_c" ]] && COMPONENTS+=("$_c")
  done < <(quant_prompt_uninstall_components "${INSTALLED[@]}")
fi

[[ ${#COMPONENTS[@]} -gt 0 ]] || quant_die "no components selected"

quant_log "will remove: ${COMPONENTS[*]}"

if [[ -z "$REMOVE_CONFIG" ]]; then
  if quant_prompt_yes_no "Also delete live configs for selected apps? [y/N] " n; then
    REMOVE_CONFIG=1
  else
    REMOVE_CONFIG=0
  fi
fi
if [[ -z "$REMOVE_DATA" ]]; then
  if quant_prompt_yes_no "Delete DATA_DIR ($DATA_DIR)? [y/N] " n; then
    REMOVE_DATA=1
  else
    REMOVE_DATA=0
  fi
fi

has_component() {
  local want="$1" c
  for c in "${COMPONENTS[@]}"; do
    [[ "$c" == "$want" ]] && return 0
  done
  return 1
}

if command -v systemctl >/dev/null 2>&1; then
  if has_component capture || has_component sessionizer || has_component quant; then
    while IFS= read -r u; do
      [[ -z "$u" ]] && continue
      systemctl disable --now "$u" 2>/dev/null || true
    done < <(systemctl list-units --type=service --all --no-legend 'quant-tape-*@*.service' 2>/dev/null | awk '{print $1}')
    while IFS= read -r u; do
      [[ -z "$u" ]] && continue
      systemctl disable --now "$u" 2>/dev/null || true
    done < <(systemctl list-units --type=target --all --no-legend 'quant-tape@*.target' 2>/dev/null | awk '{print $1}')

    for u in tape-record.target tape-capture.service tape-sessionizer.service; do
      systemctl disable --now "$u" 2>/dev/null || true
    done
  fi

  if has_component quant; then
    rm -f \
      /etc/systemd/system/quant-tape-capture@.service \
      /etc/systemd/system/quant-tape-session@.service \
      /etc/systemd/system/quant-tape@.target
    rm -rf /etc/systemd/system/quant-tape-capture@*.service.d \
      /etc/systemd/system/quant-tape-session@*.service.d 2>/dev/null || true
    systemctl daemon-reload || true
    quant_log "removed quant systemd templates"
  fi

  if has_component capture || has_component sessionizer; then
    rm -f \
      /etc/systemd/system/tape-capture.service \
      /etc/systemd/system/tape-sessionizer.service \
      /etc/systemd/system/tape-record.target
    systemctl daemon-reload || true
  fi
fi

for c in "${COMPONENTS[@]}"; do
  bin="$(quant_bin_for_component "$c")"
  quant_unlink_bin "$bin" "$PREFIX"
  rm -f "$PREFIX/bin/$bin"
  quant_log "removed $PREFIX/bin/$bin"
done

if has_component capture; then
  rm -f "$PREFIX/config/tape-capture.example.toml"
  if [[ "$REMOVE_CONFIG" == "1" ]]; then
    rm -f "$PREFIX/config/tape-capture.toml"
  fi
fi
if has_component sessionizer; then
  rm -f "$PREFIX/config/tape-sessionizer.example.toml"
  if [[ "$REMOVE_CONFIG" == "1" ]]; then
    rm -f "$PREFIX/config/tape-sessionizer.toml"
  fi
fi
if has_component quant; then
  rm -f "$PREFIX/config/quant.example.yml"
  if [[ "$REMOVE_CONFIG" == "1" ]]; then
    rm -f "$PREFIX/config/quant.yml"
  fi
fi

if [[ ! -e "$PREFIX/bin/tape-capture" \
   && ! -e "$PREFIX/bin/tape-sessionizer" \
   && ! -e "$PREFIX/bin/quant" \
   && ! -e "$PREFIX/bin/tape-lens" \
   && ! -e "$PREFIX/bin/tape-verify" ]]; then
  rm -f "$PREFIX/VERSION" "$PREFIX/manifest.json" "$PREFIX/README.tape-record.md"
  rm -f /etc/profile.d/quant-path.sh 2>/dev/null || true
fi

if [[ "$REMOVE_CONFIG" == "1" ]]; then
  quant_log "removed selected live configs"
else
  quant_log "kept live configs"
fi

if [[ "$REMOVE_DATA" == "1" ]]; then
  rm -rf "$DATA_DIR"
  quant_log "removed $DATA_DIR"
else
  quant_log "kept data at $DATA_DIR"
fi

rmdir "$PREFIX/bin" 2>/dev/null || true
rmdir "$PREFIX/config" 2>/dev/null || true
rmdir "$PREFIX" 2>/dev/null || true

quant_log "done"
