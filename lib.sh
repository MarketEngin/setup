#!/usr/bin/env bash
# Shared helpers for quant deploy install/uninstall.
# shellcheck disable=SC2034

set -euo pipefail

# Source repo that publishes per-app GitHub Releases / tags.
: "${QUANT_GIT_URL:=https://github.com/MarketEngin/MarketEngin.git}"

# Private GitHub: QUANT_GITHUB_TOKEN or GITHUB_TOKEN (never commit; chmod 600 env file).
: "${QUANT_GITHUB_TOKEN:=${GITHUB_TOKEN:-}}"

QUANT_CACHE_DIR="${QUANT_CACHE_DIR:-/var/cache/quant}"

# Per-app release asset: {bin}-linux-amd64.tar.gz
quant_asset_name_for_bin() {
  echo "${1}-linux-amd64.tar.gz"
}

# True if token looks set (non-empty).
quant_have_github_token() {
  [[ -n "${QUANT_GITHUB_TOKEN:-}" ]]
}

# Inject token into https://github.com/... URLs for git (x-access-token).
# SSH URLs left unchanged (use deploy key). Never print the result with token in logs.
quant_git_url_with_auth() {
  local url="${1:-$QUANT_GIT_URL}"
  if ! quant_have_github_token; then
    echo "$url"
    return 0
  fi
  if [[ "$url" =~ ^https://github\.com/(.+)$ ]]; then
    echo "https://x-access-token:${QUANT_GITHUB_TOKEN}@github.com/${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$url" =~ ^https://([^@]+@)?github\.com/(.+)$ ]]; then
    # Already has userinfo — leave as-is
    echo "$url"
    return 0
  fi
  echo "$url"
}

quant_github_owner_repo() {
  local url="${1:-$QUANT_GIT_URL}"
  if [[ "$url" =~ github\.com[:/]+([^/]+)/([^/.]+)(\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# Component → binary name
quant_bin_for_component() {
  case "$1" in
    capture) echo tape-capture ;;
    sessionizer) echo tape-sessionizer ;;
    quant) echo quant ;;
    lens) echo tape-lens ;;
    verify) echo tape-verify ;;
    *) return 1 ;;
  esac
}

# Component → cargo package name
quant_crate_for_component() {
  case "$1" in
    capture) echo tape-capture ;;
    sessionizer) echo tape-sessionizer ;;
    quant) echo quant ;;
    lens) echo tape-lens ;;
    verify) echo tape-verify ;;
    *) return 1 ;;
  esac
}

quant_log() { echo "quant-install: $*" >&2; }
quant_die() { quant_log "ERROR: $*"; exit 1; }

# Expand "all" or CSV into newline-separated unique components.
quant_parse_components() {
  local raw="${1:-}"
  local -a out=()
  local c
  if [[ -z "$raw" ]]; then
    quant_die "missing --components (capture,sessionizer,quant,lens,verify,all)"
  fi
  if [[ "$raw" == "all" ]]; then
    printf '%s\n' capture sessionizer quant lens verify
    return 0
  fi
  IFS=',' read -r -a parts <<<"$raw"
  for c in "${parts[@]}"; do
    c="$(echo "$c" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$c" in
      capture|sessionizer|quant|lens|verify) out+=("$c") ;;
      all)
        printf '%s\n' capture sessionizer quant lens verify
        return 0
        ;;
      *) quant_die "unknown component: $c" ;;
    esac
  done
  printf '%s\n' "${out[@]}" | awk 'NF && !seen[$0]++'
}

quant_normalize_channel() {
  local c
  c="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$c" in
    stable|release|lts) echo stable ;;
    pre-release|prerelease|dev|pre) echo pre-release ;;
    "") echo "" ;;
    *) quant_die "unknown channel: $1 (use stable|pre-release)" ;;
  esac
}

quant_prompt_channel() {
  if [[ -n "${QUANT_CHANNEL:-}" ]]; then
    quant_normalize_channel "$QUANT_CHANNEL"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo stable
    return 0
  fi
  echo "Install channel?" >&2
  echo "  [1] stable      (vX.Y.Z)" >&2
  echo "  [2] pre-release (vX.Y.Z-devN)" >&2
  local ans
  read -r -p "Choice [1]: " ans || true
  case "${ans:-1}" in
    2|pre-release|dev) echo pre-release ;;
    *) echo stable ;;
  esac
}

# Strip {app}- prefix → vX.Y.Z[-devN] (or leave unchanged if already bare).
quant_strip_app_tag_prefix() {
  local tag="$1" bin
  for bin in tape-capture tape-sessionizer quant tape-lens tape-verify; do
    if [[ "$tag" == "${bin}-v"* ]]; then
      echo "${tag#${bin}-}"
      return 0
    fi
  done
  echo "$tag"
}

# Returns 0 if tag matches channel for a given binary/app name.
# Tags: {bin}-vX.Y.Z  |  {bin}-vX.Y.Z-devN  (also accepts bare v… for tests/legacy)
quant_tag_matches_channel() {
  local tag="$1" channel="$2" app="${3:-}"
  local ver
  if [[ -n "$app" ]]; then
    [[ "$tag" == "${app}-"* ]] || return 1
  fi
  ver="$(quant_strip_app_tag_prefix "$tag")"
  case "$channel" in
    stable)
      [[ "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
      ;;
    pre-release)
      [[ "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-dev[0-9]+$ ]]
      ;;
    *) return 1 ;;
  esac
}

# Print sort key: major minor patch [devN or -1 for stable]
# Accepts bare v… or {app}-v…
quant_version_sort_key() {
  local tag ver maj min pat n
  tag="$1"
  ver="$(quant_strip_app_tag_prefix "$tag")"
  if [[ "$ver" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)-dev([0-9]+)$ ]]; then
    maj="${BASH_REMATCH[1]}"
    min="${BASH_REMATCH[2]}"
    pat="${BASH_REMATCH[3]}"
    n="${BASH_REMATCH[4]}"
    printf '%d %d %d %d\n' "$maj" "$min" "$pat" "$n"
  elif [[ "$ver" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    maj="${BASH_REMATCH[1]}"
    min="${BASH_REMATCH[2]}"
    pat="${BASH_REMATCH[3]}"
    printf '%d %d %d %d\n' "$maj" "$min" "$pat" -1
  else
    return 1
  fi
}

# Compare a b → echo -1|0|1 (a<b, equal, a>b). Same channel assumed.
quant_version_cmp() {
  local a="$1" b="$2"
  local ka kb
  ka="$(quant_version_sort_key "$a")" || quant_die "bad version: $a"
  kb="$(quant_version_sort_key "$b")" || quant_die "bad version: $b"
  read -r a1 a2 a3 a4 <<<"$ka"
  read -r b1 b2 b3 b4 <<<"$kb"
  if ((a1 != b1)); then ((a1 < b1)) && echo -1 || echo 1; return 0; fi
  if ((a2 != b2)); then ((a2 < b2)) && echo -1 || echo 1; return 0; fi
  if ((a3 != b3)); then ((a3 < b3)) && echo -1 || echo 1; return 0; fi
  if ((a4 != b4)); then ((a4 < b4)) && echo -1 || echo 1; return 0; fi
  echo 0
}

# True if a > b
quant_version_gt() {
  [[ "$(quant_version_cmp "$1" "$2")" == "1" ]]
}

# Pick highest tag from stdin for channel (optional app filter as $2).
# Usage: … | quant_pick_latest_tag stable
#        … | quant_pick_latest_tag pre-release tape-capture
quant_pick_latest_tag() {
  local channel="$1" app="${2:-}"
  local tag best=""
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    tag="${tag##*/}"
    tag="${tag%"^{}"}"
    quant_tag_matches_channel "$tag" "$channel" "$app" || continue
    if [[ -z "$best" ]]; then
      best="$tag"
      continue
    fi
    if quant_version_gt "$tag" "$best"; then
      best="$tag"
    fi
  done
  [[ -n "$best" ]] || return 1
  echo "$best"
}

quant_list_remote_tags() {
  local url out
  url="$(quant_git_url_with_auth "${1:-$QUANT_GIT_URL}")"
  command -v git >/dev/null 2>&1 || quant_die "git required for --source git"
  if ! out="$(git ls-remote --tags --refs "$url" 2>/dev/null)"; then
    if quant_have_github_token; then
      quant_die "git ls-remote failed (check QUANT_GIT_URL and QUANT_GITHUB_TOKEN scopes: Contents read)"
    fi
    quant_die "git ls-remote failed (for private GitHub set QUANT_GITHUB_TOKEN or GITHUB_TOKEN)"
  fi
  printf '%s\n' "$out" | awk '{print $2}' | sed 's#refs/tags/##'
}

# Derive GitHub API releases URL from git URL when possible.
quant_github_api_releases() {
  local or
  or="$(quant_github_owner_repo "${1:-$QUANT_GIT_URL}")" || return 1
  echo "https://api.github.com/repos/${or}/releases/tags"
}

# curl/wget with optional GitHub auth. Pass "asset" as 3rd arg for octet-stream asset download.
quant_download() {
  local url="$1" dest="$2" mode="${3:-}"
  local -a hdr=()
  if quant_have_github_token && [[ "$url" == *github* ]]; then
    hdr+=(-H "Authorization: Bearer ${QUANT_GITHUB_TOKEN}")
    hdr+=(-H "X-GitHub-Api-Version: 2022-11-28")
    if [[ "$mode" == "asset" ]]; then
      hdr+=(-H "Accept: application/octet-stream")
    else
      hdr+=(-H "Accept: application/vnd.github+json")
    fi
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${hdr[@]}" -o "$dest" -L "$url"
  elif command -v wget >/dev/null 2>&1; then
    if quant_have_github_token && [[ "$url" == *github* ]]; then
      if [[ "$mode" == "asset" ]]; then
        wget -q --header="Authorization: Bearer ${QUANT_GITHUB_TOKEN}" \
          --header="Accept: application/octet-stream" -O "$dest" "$url"
      else
        wget -q --header="Authorization: Bearer ${QUANT_GITHUB_TOKEN}" \
          --header="Accept: application/vnd.github+json" \
          --header="X-GitHub-Api-Version: 2022-11-28" -O "$dest" "$url"
      fi
    else
      wget -q -O "$dest" "$url"
    fi
  else
    quant_die "need curl or wget to download"
  fi
}

# Infer binary name from {bin}-v… tag.
quant_bin_from_tag() {
  local tag="$1" bin
  for bin in tape-capture tape-sessionizer quant tape-lens tape-verify; do
    if [[ "$tag" == "${bin}-v"* ]]; then
      echo "$bin"
      return 0
    fi
  done
  return 1
}

# Download release asset for tag into dest dir; echo path to archive or return 1.
# Asset name defaults to {bin}-linux-amd64.tar.gz for app tags.
quant_fetch_release_asset() {
  local tag="$1" dest_dir="$2" asset_name="${3:-}"
  local api asset_api_url archive json use_api_asset=0 bin
  if [[ -z "$asset_name" ]]; then
    bin="$(quant_bin_from_tag "$tag" 2>/dev/null || true)"
    if [[ -n "$bin" ]]; then
      asset_name="$(quant_asset_name_for_bin "$bin")"
    else
      asset_name="quant-linux-amd64.tar.gz"
    fi
  fi
  archive="$dest_dir/$asset_name"

  if api="$(quant_github_api_releases "$QUANT_GIT_URL")"; then
    json="$(mktemp)"
    if quant_download "${api}/${tag}" "$json" 2>/dev/null; then
      if quant_have_github_token; then
        use_api_asset=1
      fi
      asset_api_url="$(
        QUANT_USE_API="$use_api_asset" python3 - "$json" "$asset_name" <<'PY' 2>/dev/null || true
import json, os, sys
data=json.load(open(sys.argv[1]))
want=sys.argv[2]
use_api=os.environ.get("QUANT_USE_API")=="1"
assets=data.get("assets") or []
def pick(a):
    if use_api:
        return a.get("url") or ""
    return a.get("browser_download_url") or a.get("url") or ""
for a in assets:
    if a.get("name")==want:
        print(pick(a)); raise SystemExit
for a in assets:
    n=a.get("name") or ""
    if n.endswith(".tar.gz") or n.endswith(".tgz") or n.endswith(".zip"):
        print(pick(a)); raise SystemExit
PY
      )"
      rm -f "$json"
      if [[ -n "${asset_api_url:-}" ]]; then
        quant_log "downloading $asset_name from release $tag (auth=$(quant_have_github_token && echo yes || echo no))"
        if quant_have_github_token; then
          quant_download "$asset_api_url" "$archive" asset
        else
          quant_download "$asset_api_url" "$archive"
        fi
        echo "$archive"
        return 0
      fi
    else
      rm -f "$json"
      if quant_have_github_token; then
        quant_log "release API failed for $tag (need a GitHub Release on that tag + token scopes)"
      fi
    fi
  fi
  return 1
}

quant_extract_archive() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$dest" ;;
    *.zip)
      command -v unzip >/dev/null 2>&1 || quant_die "unzip required for $archive"
      unzip -q "$archive" -d "$dest"
      ;;
    *) quant_die "unsupported archive: $archive" ;;
  esac
}

# Find a directory under root that contains expected bin names (or bin/ subdir).
quant_find_bin_dir() {
  local root="$1"
  shift
  local need=("$@")
  local d candidate
  for candidate in "$root/bin" "$root"; do
    [[ -d "$candidate" ]] || continue
    local ok=1
    for d in "${need[@]}"; do
      [[ -f "$candidate/$d" || -x "$candidate/$d" ]] || { ok=0; break; }
    done
    if ((ok)); then
      echo "$candidate"
      return 0
    fi
  done
  # search one level
  local sub
  for sub in "$root"/*; do
    [[ -d "$sub" ]] || continue
    for candidate in "$sub/bin" "$sub"; do
      [[ -d "$candidate" ]] || continue
      local ok=1
      for d in "${need[@]}"; do
        [[ -f "$candidate/$d" || -x "$candidate/$d" ]] || { ok=0; break; }
      done
      if ((ok)); then
        echo "$candidate"
        return 0
      fi
    done
  done
  return 1
}

quant_cargo_packages_for_components() {
  local -a comps=("$@")
  local c
  for c in "${comps[@]}"; do
    quant_crate_for_component "$c"
  done | awk 'NF && !seen[$0]++'
}

# Build selected crates in a git work tree; echo target/release path.
quant_build_from_checkout() {
  local checkout="$1"
  shift
  local -a comps=("$@")
  local -a pkgs=()
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] && pkgs+=(-p "$p")
  done < <(quant_cargo_packages_for_components "${comps[@]}")
  command -v cargo >/dev/null 2>&1 || quant_die "cargo required to build from source"
  quant_log "cargo build --release ${pkgs[*]} (in $checkout)"
  (cd "$checkout" && cargo build --release "${pkgs[@]}")
  echo "$checkout/target/release"
}

quant_clone_tag() {
  local tag="$1" dest="$2"
  local auth_url
  auth_url="$(quant_git_url_with_auth "$QUANT_GIT_URL")"
  mkdir -p "$(dirname "$dest")"
  if [[ -d "$dest/.git" ]]; then
    quant_log "updating cache checkout $dest → $tag"
    # Refresh origin URL with current token (if any) without logging secrets.
    git -C "$dest" remote set-url origin "$auth_url" 2>/dev/null || true
    git -C "$dest" fetch --tags --depth 1 origin "$tag" 2>/dev/null \
      || git -C "$dest" fetch --tags origin
    git -C "$dest" checkout -f "$tag"
  else
    rm -rf "$dest"
    quant_log "cloning $QUANT_GIT_URL @ $tag"
    git clone --depth 1 --branch "$tag" "$auth_url" "$dest" \
      || { git clone "$auth_url" "$dest" && git -C "$dest" checkout -f "$tag"; }
  fi
}

# List components that appear installed under PREFIX/bin.
quant_installed_components() {
  local prefix="${1:-${PREFIX:-/opt/quant}}"
  local c bin
  for c in capture sessionizer quant lens verify; do
    bin="$(quant_bin_for_component "$c")"
    if [[ -x "$prefix/bin/$bin" || -f "$prefix/bin/$bin" ]]; then
      echo "$c"
    fi
  done
}

# Interactive multi-select among installed components. Prints selected names.
# Args: list of installed component names.
quant_prompt_uninstall_components() {
  local -a installed=("$@")
  local i ans
  if [[ ${#installed[@]} -eq 0 ]]; then
    quant_die "nothing installed under ${PREFIX:-/opt/quant}/bin"
  fi
  if [[ ! -t 0 ]]; then
    quant_die "non-TTY: pass --components LIST|all (installed: ${installed[*]})"
  fi
  echo "Installed components:" >&2
  for i in "${!installed[@]}"; do
    printf '  [%d] %s (%s)\n' "$((i + 1))" "${installed[$i]}" "$(quant_bin_for_component "${installed[$i]}")" >&2
  done
  echo "  [a] all" >&2
  echo "  [q] quit" >&2
  read -r -p "Remove which? (e.g. 1,3 or a): " ans || true
  ans="$(echo "${ans:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [[ -n "$ans" ]] || quant_die "nothing selected"
  [[ "$ans" == "q" ]] && quant_die "aborted"
  if [[ "$ans" == "a" || "$ans" == "all" ]]; then
    printf '%s\n' "${installed[@]}"
    return 0
  fi
  local part idx
  IFS=',' read -r -a parts <<<"$ans"
  local -a out=()
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]+$ ]] || quant_die "invalid selection: $part"
    idx=$((part - 1))
    if ((idx < 0 || idx >= ${#installed[@]})); then
      quant_die "selection out of range: $part"
    fi
    out+=("${installed[$idx]}")
  done
  printf '%s\n' "${out[@]}" | awk 'NF && !seen[$0]++'
}

quant_prompt_yes_no() {
  local prompt="$1" default="${2:-n}" ans
  if [[ ! -t 0 ]]; then
    [[ "$default" == "y" ]]
    return $?
  fi
  read -r -p "$prompt" ans || true
  ans="$(echo "${ans:-$default}" | tr '[:upper:]' '[:lower:]')"
  [[ "$ans" == "y" || "$ans" == "yes" ]]
}

# Stage bins for components into STAGING/bin from a source bin dir.
quant_stage_bins_from_dir() {
  local src_dir="$1"
  local stage_bin="$2"
  shift 2
  local -a comps=("$@")
  local c bin
  mkdir -p "$stage_bin"
  for c in "${comps[@]}"; do
    bin="$(quant_bin_for_component "$c")"
    [[ -f "$src_dir/$bin" ]] || quant_die "missing binary $src_dir/$bin"
    cp -f "$src_dir/$bin" "$stage_bin/$bin"
    chmod 755 "$stage_bin/$bin"
  done
}

quant_atomic_install_bin() {
  local src="$1" dest="$2"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    quant_log "DRY-RUN install $src → $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  local tmp="${dest}.new.$$"
  cp -f "$src" "$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$dest"
}

quant_sha256() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    echo "unknown"
  fi
}

# Write manifest. Remaining args: component names.
# Optional parallel tags via QUANT_COMPONENT_TAG_<comp> env (e.g. QUANT_COMPONENT_TAG_capture=…).
# Or pass as "comp=tag" entries mixed with bare component names.
quant_write_manifest() {
  local prefix="$1" version="$2" channel="$3" source="$4" extra="$5"
  shift 5
  local -a specs=("$@")
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    quant_log "DRY-RUN write VERSION=$version manifest"
    return 0
  fi
  echo "$version" >"$prefix/VERSION"
  local ts bin c sha tag envkey
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
  {
    echo "{"
    echo "  \"version\": \"$version\","
    echo "  \"channel\": \"$channel\","
    echo "  \"source\": \"$source\","
    echo "  \"extra\": \"$extra\","
    echo "  \"installed_at\": \"$ts\","
    echo "  \"components\": {"
    local first=1 spec
    for spec in "${specs[@]}"; do
      if [[ "$spec" == *"="* ]]; then
        c="${spec%%=*}"
        tag="${spec#*=}"
      else
        c="$spec"
        envkey="QUANT_COMPONENT_TAG_${c}"
        tag="${!envkey:-}"
      fi
      bin="$(quant_bin_for_component "$c")"
      if [[ -f "$prefix/bin/$bin" ]]; then
        sha="$(quant_sha256 "$prefix/bin/$bin")"
      else
        sha=""
      fi
      if ((first)); then first=0; else echo ","; fi
      printf '    "%s": {"bin": "%s", "tag": "%s", "sha256": "%s"}' "$c" "$bin" "$tag" "$sha"
    done
    echo
    echo "  }"
    echo "}"
  } >"$prefix/manifest.json"
}

quant_read_installed_version() {
  local prefix="$1"
  if [[ -f "$prefix/VERSION" ]]; then
    tr -d '[:space:]' <"$prefix/VERSION"
    return 0
  fi
  return 1
}

# Read installed tag for one component from manifest.json (empty if missing).
quant_read_installed_component_tag() {
  local prefix="$1" comp="$2"
  local mf="$prefix/manifest.json"
  [[ -f "$mf" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$mf" "$comp" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
c = (data.get("components") or {}).get(sys.argv[2]) or {}
tag = c.get("tag") or ""
if tag:
    print(tag)
    raise SystemExit(0)
raise SystemExit(1)
PY
}

quant_rewrite_config_paths() {
  local src="$1" dst="$2" data_dir="$3"
  sed \
    -e "s|\"./data/capture\"|\"$data_dir/capture\"|g" \
    -e "s|\"./data/sessions\"|\"$data_dir/sessions\"|g" \
    -e "s|\"./data/capture/raw-ws.ndjson\"|\"$data_dir/capture/raw-ws.ndjson\"|g" \
    "$src" >"$dst"
}

quant_ensure_user_and_dirs() {
  local prefix="$1" data_dir="$2"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    quant_log "DRY-RUN ensure user quant + dirs under $prefix $data_dir"
    return 0
  fi
  if [[ "$(uname -s)" == "Linux" ]] && [[ "$(id -u)" -eq 0 ]]; then
    id -u quant >/dev/null 2>&1 || \
      useradd --system --home "$prefix" --shell /usr/sbin/nologin quant
  fi
  mkdir -p "$prefix/bin" "$prefix/config" "$data_dir/capture" "$data_dir/sessions"
}

quant_install_unit_templates() {
  local unit_src="$1"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    quant_log "DRY-RUN install systemd templates from $unit_src"
    return 0
  fi
  if [[ ! -d /etc/systemd/system ]]; then
    quant_log "systemd not available — skipping unit templates"
    return 0
  fi
  local f
  for f in quant-tape-capture@.service quant-tape-session@.service quant-tape@.target; do
    [[ -f "$unit_src/$f" ]] || quant_die "missing unit template $unit_src/$f"
    install -m 644 "$unit_src/$f" "/etc/systemd/system/$f"
    quant_log "installed /etc/systemd/system/$f"
  done
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
  fi
}

quant_migrate_legacy_units() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  command -v systemctl >/dev/null 2>&1 || return 0
  if systemctl is-enabled tape-record.target >/dev/null 2>&1 \
    || systemctl is-active tape-record.target >/dev/null 2>&1; then
    quant_log "disabling legacy tape-record.target (use: quant -f … up -d)"
    systemctl disable --now tape-record.target 2>/dev/null || true
  fi
}

quant_restart_sessionizers() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    quant_log "DRY-RUN restart sessionizer units"
    return 0
  fi
  command -v systemctl >/dev/null 2>&1 || return 0
  local u
  # Legacy
  if systemctl is-active tape-sessionizer.service >/dev/null 2>&1; then
    systemctl restart tape-sessionizer.service || true
  fi
  # Template instances
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    systemctl restart "$u" || true
    quant_log "restarted $u"
  done < <(systemctl list-units --type=service --state=running --no-legend 'quant-tape-session@*.service' 2>/dev/null | awk '{print $1}')
}

quant_restart_captures() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    quant_log "DRY-RUN restart capture units"
    return 0
  fi
  command -v systemctl >/dev/null 2>&1 || return 0
  if systemctl is-active tape-capture.service >/dev/null 2>&1; then
    systemctl restart tape-capture.service || true
  fi
  local u
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    systemctl restart "$u" || true
    quant_log "restarted $u"
  done < <(systemctl list-units --type=service --state=running --no-legend 'quant-tape-capture@*.service' 2>/dev/null | awk '{print $1}')
}

# Self-test for version helpers (no network).
quant_lib_selftest() {
  set -e
  quant_tag_matches_channel "v1.2.3" stable
  ! quant_tag_matches_channel "v1.2.3-dev0" stable
  quant_tag_matches_channel "v1.2.3-dev0" pre-release
  ! quant_tag_matches_channel "v1.2.3" pre-release
  quant_tag_matches_channel "tape-capture-v1.2.3" stable tape-capture
  quant_tag_matches_channel "tape-capture-v1.2.3-dev0" pre-release tape-capture
  ! quant_tag_matches_channel "quant-v1.2.3" stable tape-capture
  [[ "$(quant_strip_app_tag_prefix tape-lens-v0.1.0-dev2)" == "v0.1.0-dev2" ]]
  [[ "$(quant_version_cmp v1.2.3 v1.2.10)" == "-1" ]]
  [[ "$(quant_version_cmp tape-capture-v1.2.10 tape-capture-v1.2.3)" == "1" ]]
  [[ "$(quant_version_cmp v1.2.3-dev0 v1.2.3-dev1)" == "-1" ]]
  [[ "$(quant_version_cmp tape-capture-v1.2.3-dev10 tape-capture-v1.2.3-dev2)" == "1" ]]
  [[ "$(quant_version_cmp v1.2.3-dev0 v1.2.3-dev0)" == "0" ]]
  local latest
  latest="$(printf '%s\n' v1.0.0 v1.2.3 v1.2.10 v2.0.0-dev0 | quant_pick_latest_tag stable)"
  [[ "$latest" == "v1.2.10" ]]
  latest="$(printf '%s\n' \
    tape-capture-v1.0.0 tape-capture-v1.2.3 quant-v9.0.0 tape-capture-v1.2.10 \
    | quant_pick_latest_tag stable tape-capture)"
  [[ "$latest" == "tape-capture-v1.2.10" ]]
  latest="$(printf '%s\n' \
    tape-capture-v1.2.3-dev0 tape-capture-v1.2.3-dev10 tape-capture-v1.2.3-dev2 quant-v1.3.0-dev0 \
    | quant_pick_latest_tag pre-release tape-capture)"
  [[ "$latest" == "tape-capture-v1.2.3-dev10" ]]
  [[ "$(quant_asset_name_for_bin quant)" == "quant-linux-amd64.tar.gz" ]]
  [[ "$(quant_bin_from_tag tape-sessionizer-v1.0.0-dev0)" == "tape-sessionizer" ]]
  echo "quant_lib_selftest: ok"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] && [[ "${1:-}" == "--selftest" ]]; then
  quant_lib_selftest
fi
