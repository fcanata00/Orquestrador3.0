#!/usr/bin/env bash
# pkg.sh
# Gestão de pacotes: fetch, unpack, apply patches, pack, install-pkg, uninstall
# Dependências: core.sh, envctl.sh (for LFS variable)

set -euo pipefail
IFS=$'\n\t'

SCRIPTDIR="${SCRIPTDIR:-$(dirname "${BASH_SOURCE[0]}")}"
# shellcheck source=core.sh
source "$SCRIPTDIR/core.sh"

LFS="${LFS:-/mnt/lfs}"
SOURCES_DIR="${SOURCES_DIR:-$LFS/sources}"
SOURCE_CACHE="${SOURCE_CACHE:-$LFS/sources/cache}"
BUILD_DIR="${BUILD_DIR:-$LFS/build}"
PACKAGE_OUTPUT="${PACKAGE_OUTPUT:-$LFS/packages}"
MANIFESTS_DIR="${MANIFESTS_DIR:-$LFS/manifests}"
LOG_DIR="${LOG_DIR:-$LFS/logs}"

mkdir -p "$SOURCES_DIR" "$SOURCE_CACHE" "$BUILD_DIR" "$PACKAGE_OUTPUT" "$MANIFESTS_DIR" "$LOG_DIR"

# helpers
_recipe_path() { printf "%s/recipes/%s.recipe" "$SCRIPTDIR" "$1"; }

# read recipe variables into environment (safe subshell)
_load_recipe_vars() {
  local pkg="$1" recipe
  recipe=$(_recipe_path "$pkg")
  if [[ ! -f "$recipe" ]]; then
    die "recipe not found for package: $pkg"
  fi
  # shellcheck disable=SC1090
  # source in subshell to extract variables
  ( source "$recipe"; env | grep -E '^(pkgname|version|urls|sha256|depends|revision|patch_urls)=' )
}

# fetch sources (supports http(s), ftp, rsync, git+)
cmd_fetch() {
  local pkg="$1"; shift
  local recipe=$(_recipe_path "$pkg")
  if [[ ! -f "$recipe" ]]; then
    die "recipe not found: $recipe"
  fi
  # load arrays/vars by sourcing recipe in subshell
  # We'll eval safely to get arrays
  local urls_var sha exp rev
  urls_var=$(awk -F= '/^urls\=/ {print substr($0, index($0,$2))}' "$recipe" 2>/dev/null || true)
  # fallback single url
  local default_url
  default_url=$(awk -F= '/^url\=/ {print substr($0, index($0,$2))}' "$recipe" 2>/dev/null || true)

  # Extract declared sha256 if present
  sha=$(awk -F= '/^sha256\=/ {print substr($0, index($0,$2))}' "$recipe" 2>/dev/null | tr -d '"') || true
  # naive parsing: look for git+ in recipe file
  mapfile -t candidate_urls < <(grep -E "^urls?=|^url=" -n "$recipe" | sed -E 's/^[0-9]+://' | sed 's/^urls=//;s/^url=//' | tr -d '"' | sed 's/[()]//g' | tr -s ' ' '\n' | sed '/^\s*$/d')
  if [[ ${#candidate_urls[@]} -eq 0 && -n "$default_url" ]]; then
    candidate_urls=("$default_url")
  fi

  local out
  for u in "${candidate_urls[@]}"; do
    u=$(echo "$u" | sed 's/^\s*//;s/\s*$//')
    if [[ -z "$u" ]]; then continue; fi
    # handle git URLs
    if [[ "$u" == git+* ]]; then
      local giturl=${u#git+}
      local revline
      revline=$(awk -F= '/^revision\=/ {print substr($0, index($0,$2))}' "$recipe" 2>/dev/null || true)
      rev=$(echo "$revline" | tr -d '"') || true
      local dest="$SOURCE_CACHE/$pkg"
      mkdir -p "$dest"
      local clone_dir="$dest/$(basename "$giturl" .git)-${rev:-latest}"
      if [[ -d "$clone_dir/.git" ]]; then
        info "git repo already present: $clone_dir"
        echo "$clone_dir"
        return 0
      fi
      info "cloning $giturl -> $clone_dir"
      run_and_log "$pkg-fetch" -- git clone --depth 1 ${rev:+--branch $rev} "$giturl" "$clone_dir"
      echo "$clone_dir"
      return 0
    fi

    local filename
    filename=$(basename "$u")
    local cached="$SOURCE_CACHE/$pkg/$filename"
    mkdir -p "$(dirname "$cached")"

    if [[ -f "$cached" ]]; then
      if [[ -n "$sha" ]]; then
        if verify_checksum "$cached" "$sha" >/dev/null 2>&1; then
          info "using cached source $cached"
          echo "$cached"; return 0
        else
          warn "cached file checksum mismatch, re-downloading"
          mv "$cached" "$cached.bad.$(date +%s)" || true
        fi
      else
        info "using cached source $cached (no checksum)"
        echo "$cached"; return 0
      fi
    fi

    info "attempting download $u"
    if download "$u" "$cached"; then
      if [[ -n "$sha" ]]; then
        if ! verify_checksum "$cached" "$sha"; then
          error "checksum failed for $cached"
          continue
        fi
      fi
      echo "$cached"; return 0
    fi
  done
  die "failed to fetch any source for $pkg"
}

# unpack
cmd_unpack() {
  local pkg="$1"
  local srcpath
  srcpath=$(cmd_fetch "$pkg")
  local dest="$BUILD_DIR/$pkg-$(date +%s)"
  mkdir -p "$dest"
  if [[ -d "$srcpath/.git" ]]; then
    info "copying git tree to build dir"
    run_and_log "$pkg-unpack" -- git -C "$srcpath" archive --format=tar HEAD | tar -x -C "$dest"
  else
    info "extracting $srcpath to $dest"
    extract_archive "$srcpath" "$dest"
  fi
  echo "$dest"
}

# apply patches from patches/<pkg>/NN-*.patch or patch_urls in recipe
cmd_apply_patches() {
  local pkg="$1"
  local workdir="$2"
  local patchdir="$SCRIPTDIR/patches/$pkg"
  if [[ -d "$patchdir" ]]; then
    info "applying local patches from $patchdir"
    for p in "$patchdir"/*; do
      [[ -f "$p" ]] || continue
      info "applying patch $p"
      run_and_log "$pkg-patch" -- patch -p1 -d "$workdir" <"$p"
    done
  fi
  # also support remote patch_urls declared in recipe
  local recipe="$(_recipe_path "$pkg")"
  mapfile -t purls < <(awk -F= '/^patch_urls\=/,/^\)/{print}' "$recipe" 2>/dev/null | tr -d '()' | tr -d '"' | tr -s ' ' '\n' | sed '/^\s*$/d' ) || true
  if [[ ${#purls[@]} -gt 0 ]]; then
    mkdir -p "$SOURCE_CACHE/patches/$pkg"
    for pu in "${purls[@]}"; do
      pu=$(echo "$pu" | tr -d '"')
      local fname
      fname=$(basename "$pu")
      local cached="$SOURCE_CACHE/patches/$pkg/$fname"
      if [[ -f "$cached" ]]; then
        info "using cached patch $cached"
      else
        info "downloading patch $pu"
        download "$pu" "$cached"
      fi
      info "applying patch $cached"
      run_and_log "$pkg-patch" -- patch -p1 -d "$workdir" <"$cached"
    done
  fi
}

# create install-list and hashes
_create_install_list() {
  local destdir="$1"
  local out="$2"
  pushd "$destdir" >/dev/null
  find . -type f -print0 | xargs -0 sha256sum | sed 's|\./||' >"$out"
  popd >/dev/null
}

# strip binaries in destdir
_strip_destdir() {
  local destdir="$1"
  local logtag="$2"
  local -a paths=("bin" "sbin" "usr/bin" "usr/sbin" "lib" "usr/lib")
  for p in "${paths[@]}"; do
    local full="$destdir/$p"
    if [[ -d "$full" ]]; then
      while IFS= read -r -d '' f; do
        # detect ELF
        if file "$f" | grep -q ELF; then
          # skip setuid
          if [[ -u "$f" ]]; then
            warn "skipping strip on setuid file $f"
            continue
          fi
          info "stripping $f"
          safe_cmd "$STRIP_CMD" $STRIP_FLAGS_BIN "$f" || warn "strip failed for $f"
        fi
      done < <(find "$full" -type f -print0)
    fi
  done
}

# pack destdir into package tar.zst
cmd_pack() {
  local pkg="$1" version="$2" destdir="$3"
  local out="$PACKAGE_OUTPUT/${pkg}-${version}-lfs.tar.zst"
  mkdir -p "$PACKAGE_OUTPUT"
  info "packing $pkg $version -> $out"
  # create MANIFEST and install-list
  local manifest_dir="$destdir/.PKGINFO"
  mkdir -p "$manifest_dir"
  printf "pkgname=%s\nversion=%s\nbuild_id=%s\n" "$pkg" "$version" "$(date +%s)" >"$manifest_dir/MANIFEST"
  _create_install_list "$destdir" "$manifest_dir/install-list.txt"
  # include MANIFEST in tar
  if command -v zstd >/dev/null 2>&1; then
    tar -C "$destdir" -cf - . | zstd -19 -T0 -o "$out"
  else
    tar -C "$destdir" -cf - . | xz -9e -c >"$out"
  fi
  info "package created: $out"
  # register package
  printf "%s\t%s\t%s\n" "$pkg" "$version" "$out" >>"$MANIFESTS_DIR/versions.tsv"
  echo "$out"
}

# install package tarball to LFS atomically
cmd_install_pkg() {
  local tarball="$1"
  local tmpdir="$LFS/.install-tmp/$(basename "$tarball")-$$"
  mkdir -p "$tmpdir"
  info "installing package $tarball -> $LFS (tmp: $tmpdir)"
  if command -v zstd >/dev/null 2>&1; then
    run_and_log install -- sh -c "unzstd -c '$tarball' | tar -x -C '$tmpdir'"
  else
    run_and_log install -- sh -c "tar -xJf '$tarball' -C '$tmpdir'"
  fi
  # rsync into LFS root (atomic-ish)
  run_and_log install -- rsync -a --delete-after --checksum --backup-dir="$LFS/.install-backup/$(basename "$tarball")-$(date +%s)" "$tmpdir/" "$LFS/"
  # record installed package
  local pkgname version
  pkgname=$(basename "$tarball" | cut -d- -f1)
  version=$(basename "$tarball" | cut -d- -f2)
  printf "%s\t%s\t%s\n" "$pkgname" "$version" "$tarball" >>"$MANIFESTS_DIR/installed.tsv"
  rm -rf "$tmpdir"
  info "installed $tarball"
}

# uninstall package by reading install-list
cmd_uninstall() {
  local pkg="$1" force=${2:-0}
  local instfile
  instfile=$(grep -P "^$pkg\t" -m1 "$MANIFESTS_DIR/installed.tsv" | awk -F'\t' '{print $3}' || true)
  if [[ -z "$instfile" ]]; then
    die "package $pkg not recorded as installed"
  fi
  local tmpdir="$LFS/.uninstall-tmp/$(basename "$pkg")-$$"
  mkdir -p "$tmpdir"
  if [[ ! -f "$instfile" ]]; then
    die "original package tarball not found: $instfile"
  fi
  # extract install-list
  if command -v zstd >/dev/null 2>&1; then
    tar -C "$tmpdir" -xf <(unzstd -c "$instfile") || true
  else
    tar -C "$tmpdir" -xf "$instfile" || true
  fi
  if [[ ! -f "$tmpdir/.PKGINFO/install-list.txt" ]]; then
    die "install-list not found inside package"
  fi
  pushd "$LFS" >/dev/null
  while read -r line; do
    local path
    path="$line"
    if [[ -f "$path" ]]; then
      if [[ $force -eq 1 ]]; then
        rm -f "$path"
        info "removed $path"
      else
        # compare hash
        local want
        want=$(grep -F " $path" "$tmpdir/.PKGINFO/install-list.txt" | awk '{print $1}') || true
        if [[ -n "$want" ]]; then
          local got
          got=$(sha256sum "$path" | awk '{print $1}') || true
          if [[ "$got" == "$want" ]]; then
            rm -f "$path"; info "removed $path"
          else
            warn "file modified since install, skipping $path (use --force to remove)"
          fi
        else
          warn "no hash for $path, skipping"
        fi
      fi
    fi
  done < <(sed 's/^[ ]*//;s/[ ]*$//' "$tmpdir/.PKGINFO/install-list.txt" | awk '{print $2}')
  popd >/dev/null
  # remove installed.tsv line
  grep -vP "^$pkg\t" "$MANIFESTS_DIR/installed.tsv" >"$MANIFESTS_DIR/installed.tsv.tmp" && mv "$MANIFESTS_DIR/installed.tsv.tmp" "$MANIFESTS_DIR/installed.tsv"
  rm -rf "$tmpdir"
  info "uninstall of $pkg completed"
}

# public CLI
_usage() {
  cat <<EOF
Usage: $0 <command> [args]
Commands:
  fetch <pkg>
  unpack <pkg>
  apply-patches <pkg> <workdir>
  pack <pkg> <version> <destdir>
  install-pkg <tarball>
  uninstall <pkg> [--force]
  clean-cache [--pkg <pkg>]
EOF
}

if [[ $# -lt 1 ]]; then _usage; exit 1; fi
cmd="$1"; shift
case "$cmd" in
  fetch) cmd_fetch "$@" ;;
  unpack) cmd_unpack "$@" ;;
  apply-patches) cmd_apply_patches "$@" ;;
  pack) cmd_pack "$@" ;;
  install-pkg) cmd_install_pkg "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  *) _usage; exit 1 ;;
esac
