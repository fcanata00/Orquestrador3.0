#!/usr/bin/env bash
# core.sh
# Biblioteca central de utilitários para o LFS build system
# - fornece logging, locks, download, checksum, run_and_log, trap handlers
# - projetado para ser `source`d por outros scripts

set -euo pipefail
IFS=$'\n\t'

# ------------------------------
# Configuração default (podem ser sobrescritas por lfs.conf)
# ------------------------------
LOG_DIR="${LFS:-/mnt/lfs}/logs"
LOCK_DIR="/var/lock/lfs-system"
SOURCE_CACHE="${LFS:-/mnt/lfs}/sources/cache"
DOWNLOAD_RETRIES=${DOWNLOAD_RETRIES:-3}
DOWNLOAD_BACKOFF=${DOWNLOAD_BACKOFF:-3}
LOCK_STALE_SECONDS=${LOCK_STALE_SECONDS:-86400}
PACKAGE_OUTPUT="${LFS:-/mnt/lfs}/packages"
MANIFESTS_DIR="${LFS:-/mnt/lfs}/manifests"
BUILD_DIR="${LFS:-/mnt/lfs}/build"
SOURCES_DIR="${LFS:-/mnt/lfs}/sources"

# Ensure directories exist (caller pode ajustar LFS antes de source)
mkdir -p "$LOG_DIR" || true
mkdir -p "$LOCK_DIR" || true
mkdir -p "$SOURCE_CACHE" || true
mkdir -p "$PACKAGE_OUTPUT" || true
mkdir -p "$MANIFESTS_DIR" || true
mkdir -p "$BUILD_DIR" || true
mkdir -p "$SOURCES_DIR" || true

# ------------------------------
# Helpers de logging
# ------------------------------
_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_file_for() {
  local tag=${1:-system}
  printf "%s/%s.log" "$LOG_DIR" "$tag"
}

log() {
  local level="$1"; shift
  local msg="$*"
  local t
  t=$(_timestamp)
  local tag=${LOG_TAG:-system}
  local lf
  lf=$(log_file_for "$tag")
  printf "%s [%s] %s\n" "$t" "$level" "$msg" | tee -a "$lf" >&2
}

info()  { log INFO "$*"; }
warn()  { log WARN "$*"; }
error() { log ERROR "$*"; }

die() {
  local rc=${2:-1}
  error "$1"
  exit "$rc"
}

# ------------------------------
# run_and_log: executa comando e redireciona stdout/stderr para log
# usage: run_and_log <logtag> -- cmd args...
# ------------------------------
run_and_log() {
  local tag
  if [[ "$1" == "--" ]]; then
    die "run_and_log needs a tag before --"
  fi
  tag="$1"; shift
  if [[ "$1" != "--" ]]; then
    die "run_and_log usage: run_and_log <tag> -- <cmd>"
  fi
  shift

  local lf
  lf=$(log_file_for "$tag")
  LOG_TAG="$tag"
  info "[${tag}] Running: $*"

  # Execute command capturing stdout/stderr
  local tmpout tmperr rc
  tmpout=$(mktemp)
  tmperr=$(mktemp)
  set +e
  "$@" >"$tmpout" 2>"$tmperr"
  rc=$?
  set -e

  # Append outputs to log
  if [[ -s "$tmpout" ]]; then
    printf "--- STDOUT ---\n" >>"$lf"
    cat "$tmpout" >>"$lf"
  fi
  if [[ -s "$tmperr" ]]; then
    printf "--- STDERR ---\n" >>"$lf"
    cat "$tmperr" >>"$lf"
  fi

  rm -f "$tmpout" "$tmperr"

  if [[ $rc -ne 0 ]]; then
    error "[${tag}] Command failed with exit $rc: $*"
  else
    info "[${tag}] Command finished: $*"
  fi
  return $rc
}

# safe_cmd: executa comando que pode falhar sem abortar
# registra warning em caso de falha
safe_cmd() {
  set +e
  "$@"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    warn "non-fatal command failed (exit $rc): $*"
  fi
  return $rc
}

# ------------------------------
# Locking primitives
# ------------------------------
_acquire_lock_flock() {
  local lockfile="$1"
  exec 9>"$lockfile" || return 1
  flock -n 9 || return 1
  printf "%s\n" "$$" >&9
  return 0
}

_acquire_lock_mkdir() {
  local lockdir="$1"
  if mkdir "$lockdir" 2>/dev/null; then
    printf "%s\n" "$(hostname) $$ $(date -u +%s)" >"$lockdir/owner"
    return 0
  else
    return 1
  fi
}

acquire_lock() {
  local name=${1:-global}
  local lockfile="$LOCK_DIR/$name.lock"
  local lockdir="$LOCK_DIR/$name.lockdir"

  # Try flock first
  if command -v flock >/dev/null 2>&1; then
    if _acquire_lock_flock "$lockfile"; then
      info "acquired flock lock $lockfile (fd 9)"
      echo "$lockfile" >"/tmp/lfs-lock-$name" || true
      return 0
    fi
  fi

  # Fallback to mkdir-based lock
  if _acquire_lock_mkdir "$lockdir"; then
    info "acquired mkdir lock $lockdir"
    echo "$lockdir" >"/tmp/lfs-lock-$name" || true
    return 0
  fi

  # Check for stale lock
  if [[ -f "$lockdir/owner" ]]; then
    local owner_info
    owner_info=$(cat "$lockdir/owner" 2>/dev/null || true)
    warn "lock $name held by: $owner_info"
  fi
  return 1
}

release_lock() {
  local name=${1:-global}
  local lockfile="$LOCK_DIR/$name.lock"
  local lockdir="$LOCK_DIR/$name.lockdir"
  if [[ -f "/tmp/lfs-lock-$name" ]]; then
    local v
    v=$(cat "/tmp/lfs-lock-$name" 2>/dev/null || true)
    rm -f "/tmp/lfs-lock-$name" || true
  fi

  if [[ -e "$lockfile" ]]; then
    # attempt to remove and close fd 9 if present
    rm -f "$lockfile" || true
    info "released flock lock $lockfile"
  fi
  if [[ -d "$lockdir" ]]; then
    rm -rf "$lockdir" || true
    info "released mkdir lock $lockdir"
  fi
}

# ------------------------------
# checksum verification
# ------------------------------
verify_checksum() {
  local file="$1" expected="$2"
  local algo=${3:-sha256}
  if [[ ! -f "$file" ]]; then
    error "verify_checksum: file not found: $file"
    return 2
  fi
  case "$algo" in
    sha256) local got; got=$(sha256sum "$file" | awk '{print $1}') ;;
    sha512) local got; got=$(sha512sum "$file" | awk '{print $1}') ;;
    md5)    local got; got=$(md5sum "$file" | awk '{print $1}') ;;
    *) die "unsupported checksum algorithm: $algo" ;;
  esac
  if [[ "$got" != "$expected" ]]; then
    warn "checksum mismatch for $file: expected $expected got $got"
    return 1
  fi
  info "checksum ok for $file"
  return 0
}

# ------------------------------
# download with mirrors, retries and cache
# ------------------------------
_download_once() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -L --retry 3 --retry-delay 5 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    die "no downloader (curl or wget) available"
  fi
}

download() {
  local url="$1"
  local out="$2"
  local retries=${3:-$DOWNLOAD_RETRIES}
  local backoff=${4:-$DOWNLOAD_BACKOFF}

  local i=0
  while true; do
    if _download_once "$url" "$out"; then
      info "downloaded $url -> $out"
      return 0
    fi
    i=$((i+1))
    if [[ $i -ge $retries ]]; then
      error "download failed after $i attempts: $url"
      return 1
    fi
    warn "download failed, retrying in $backoff seconds... ($i/$retries)"
    sleep "$backoff"
    backoff=$((backoff * 2))
  done
}

# download with cache logic
cached_fetch() {
  local pkg="$1" url="$2" expected_sha="$3"
  mkdir -p "$SOURCE_CACHE/$pkg"
  local filename
  filename=$(basename "$url")
  local cached="$SOURCE_CACHE/$pkg/$filename"
  if [[ -f "$cached" ]]; then
    if [[ -n "$expected_sha" ]]; then
      if verify_checksum "$cached" "$expected_sha" >/dev/null 2>&1; then
        info "using cached source $cached"
        echo "$cached"
        return 0
      else
        warn "cached file checksum mismatch, redownloading"
        mv "$cached" "$cached.bad.$(date +%s)" || true
      fi
    else
      info "using cached source $cached (no checksum provided)"
      echo "$cached"
      return 0
    fi
  fi

  mkdir -p "$(dirname "$cached")"
  if download "$url" "$cached"; then
    if [[ -n "$expected_sha" ]]; then
      if ! verify_checksum "$cached" "$expected_sha"; then
        error "downloaded file checksum mismatch for $url"
        return 2
      fi
    fi
    echo "$cached"
    return 0
  fi
  return 1
}

# ------------------------------
# archive extraction helper
# ------------------------------
extract_archive() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  case "$archive" in
    *.tar.gz|*.tgz)   tar -xzf "$archive" -C "$dest" ;;
    *.tar.xz)         tar -xJf "$archive" -C "$dest" ;;
    *.tar.zst)        if command -v zstd >/dev/null 2>&1; then
                        tar --use-compress-program=unzstd -xf "$archive" -C "$dest"
                      else
                        die "zstd required to extract $archive"
                      fi ;;
    *.zip)            unzip -q "$archive" -d "$dest" ;;
    *.tar.bz2)        tar -xjf "$archive" -C "$dest" ;;
    *.git.tar*|*.git.zip)
                      # generic: try tar then unzip
                      if tar -tf "$archive" >/dev/null 2>&1; then
                        tar -xf "$archive" -C "$dest"
                      else
                        unzip -q "$archive" -d "$dest"
                      fi ;;
    *) die "unsupported archive type: $archive" ;;
  esac
}

# ------------------------------
# recipe loader: sources a .recipe file in a subshell
# Exports: pkgname, version, urls, sha256, depends
# ------------------------------
load_recipe() {
  local recipe="$1"
  if [[ ! -f "$recipe" ]]; then
    die "recipe not found: $recipe"
  fi
  # shellcheck disable=SC1090
  # We source the recipe in a subshell to avoid pollution
  ( source "$recipe"; printf "__LOADED__\n" )
}

# ------------------------------
# Topological sort for dependencies
# Input: list of pkgnames and usage of recipe lookup function
# This basic implementation expects a function recipe_deps <pkg>
# that prints deps separated by newlines
# ------------------------------
_topo_sort() {
  local pkgs=($@)
  declare -A state # 0=unvisited,1=visiting,2=visited
  local result=()
  local cycle_found=0

  _dfs() {
    local p="$1"
    if [[ ${state[$p]:-0} -eq 1 ]]; then
      echo "CYCLE_DETECTED:$p"
      cycle_found=1
      return
    fi
    if [[ ${state[$p]:-0} -eq 2 ]]; then
      return
    fi
    state[$p]=1
    local deps
    deps=$(recipe_deps "$p" || true)
    local dep
    while read -r dep; do
      [[ -z "$dep" ]] && continue
      _dfs "$dep"
    done <<<"$deps"
    state[$p]=2
    result+=("$p")
  }

  for p in "${pkgs[@]}"; do
    _dfs "$p"
  done

  if [[ $cycle_found -ne 0 ]]; then
    echo "" >&2
    return 1
  fi

  # print in order (dependencies before dependents)
  for ((i=${#result[@]}-1;i>=0;i--)); do
    printf "%s\n" "${result[i]}"
  done
}

# recipe_deps is expected to be provided by the caller script.
# Provide a default that looks into recipes/<pkg>.recipe
recipe_deps() {
  local pkg="$1"
  local r="${SCRIPTDIR:-.}/recipes/$pkg.recipe"
  if [[ -f "$r" ]]; then
    # shellcheck disable=SC1090
    # read depends array without sourcing functions
    # We'll parse lines starting with depends=( ... ) naively
    awk '/^depends=\(/,/^\)/{print}' "$r" 2>/dev/null | tr -d '()' | tr -d '"' | tr -s ' ' '\n' | sed '/^\s*$/d'
  fi
}

# ------------------------------
# small utility: absolute path canonicalize
# ------------------------------
abspath() {
  python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1"
}

# ------------------------------
# Trap handlers
# ------------------------------
_on_exit() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    error "Script exiting with code $rc"
  else
    info "Script exiting normally"
  fi
}
trap _on_exit EXIT

# ------------------------------
# End of core.sh
# ------------------------------
