#!/usr/bin/env bash
# lfs-build.sh
# Orquestrador principal (VERSÃO ATUALIZADA)
# - Executa builds dentro do chroot (modo `chroot` conforme solicitado)
# - Integra com core.sh, pkg.sh e envctl.sh
# - Usa copy dos scripts para dentro do chroot antes do build para garantir disponibilidade
# - Implementa fetch->unpack->patch->build(in-chroot)->install(destdir,in-chroot)->strip(in-chroot)->pack(host)

set -euo pipefail
IFS=$'
	'

SCRIPTDIR="${SCRIPTDIR:-$(dirname "${BASH_SOURCE[0]}")}"
# shellcheck source=core.sh
source "$SCRIPTDIR/core.sh"
# source pkg.sh to reuse helpers when running on the host (not inside chroot)
# shellcheck source=pkg.sh
source "$SCRIPTDIR/pkg.sh"

ENVCTL="$SCRIPTDIR/envctl.sh"
LFS="${LFS:-/mnt/lfs}"
BUILD_DIR="${BUILD_DIR:-$LFS/build}"
PACKAGE_OUTPUT="${PACKAGE_OUTPUT:-$LFS/packages}"
MANIFESTS_DIR="${MANIFESTS_DIR:-$LFS/manifests}"
PARALLEL=${PARALLEL:-1}
POST_UPGRADE_CHECK_SECONDS=${POST_UPGRADE_CHECK_SECONDS:-60}
BACKUP_KEEP_DAYS=${BACKUP_KEEP_DAYS:-7}

mkdir -p "$BUILD_DIR" "$PACKAGE_OUTPUT" "$MANIFESTS_DIR"

_usage() {
  cat <<EOF
Usage: $0 <command> [options]
Commands:
  build --pkg <pkg>            Build single package (inside chroot as BUILD_USER)
  build --group <group>        Build group defined in recipes/groups/<group>.list
  build --stage <bootstrap|base|blfs>
  update-all [--parallel N] [--rebuild-depends]
  upgrade --pkg <pkg>
  --resume                      Resume from last checkpoint
  --help

Notes:
  - This orchestrator will COPY the scripts directory into $LFS/tmp/lfs-scripts
    before running the build inside chroot so the same helper scripts are
    available in the chroot environment.
EOF
}

# Ensure envctl is available
if [[ ! -x "$ENVCTL" ]]; then
  die "envctl.sh not found or not executable at $ENVCTL"
fi

# copy scripts into chroot so builds can source them inside
_copy_scripts_to_chroot() {
  local dest="$LFS/tmp/lfs-scripts"
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  info "copying build scripts to chroot: $dest"
  rsync -a --delete "$SCRIPTDIR/" "$dest/"
  # ensure permissions
  chmod -R a+rX "$dest"
}

# prepare workdir inside LFS for building
_prepare_chroot_workdir() {
  local pkg="$1" version="$2" src_host_dir="$3"
  local chroot_src_dir="/build/${pkg}-${version}/src"
  local chroot_build_dir="/build/${pkg}-${version}"
  # create dirs in LFS
  mkdir -p "$LFS/build/${pkg}-${version}"
  # copy source tree into LFS build src
  info "syncing source to chroot build dir"
  rsync -a --delete "$src_host_dir/" "$LFS$chroot_src_dir/"
  echo "$chroot_src_dir"
}

# run a command inside chroot as BUILD_USER (via envctl.sh enter)
# passes SCRIPTDIR=/tmp/lfs-scripts inside chroot
_chroot_run() {
  local cmd="$*"
  run_and_log chrootCmd -- "$ENVCTL" enter /bin/bash -lc "export SCRIPTDIR=/tmp/lfs-scripts && $cmd"
}

# build package inside chroot
_build_in_chroot() {
  local pkg="$1" version="$2" chroot_src_dir="$3" chroot_build_dir="/build/${pkg}-${version}"

  info "starting in-chroot build for $pkg (src: $chroot_src_dir)"

  # inside chroot: cd to src and run recipe build/install
  # The recipe will be available at /tmp/lfs-scripts/recipes/<pkg>.recipe
  local build_script=""
  build_script+="cd $chroot_src_dir && "
  build_script+="source /tmp/lfs-scripts/core.sh && source /tmp/lfs-scripts/pkg.sh && "
  build_script+="source /tmp/lfs-scripts/recipes/$pkg.recipe || true && "
  # run build() if present, else try default sequence
  build_script+="( if declare -f build >/dev/null 2>&1; then echo 'recipe build() found'; build || exit 1; else echo 'default: ./configure && make'; ./configure || true; make -j\$(nproc) || exit 1; fi ) && "
  # run install into DESTDIR
  build_script+="mkdir -p $chroot_build_dir/destdir && "
  build_script+="( if declare -f install >/dev/null 2>&1; then fakeroot bash -lc \"install DESTDIR='$chroot_build_dir/destdir' || exit 1\"; else fakeroot make DESTDIR='$chroot_build_dir/destdir' install || exit 1; fi )"

  # Execute inside chroot as BUILD_USER
  _chroot_run "$build_script"
}

# strip and pack inside chroot or pack on host? We will strip inside chroot (uses chroot toolchain)
_strip_and_pack_in_chroot() {
  local pkg="$1" version="$2"
  local chroot_build_dir="/build/${pkg}-${version}"
  local chroot_destdir="$chroot_build_dir/destdir"
  local pack_cmd

  # run strip inside chroot by invoking pkg.sh's strip helper
  pack_cmd="source /tmp/lfs-scripts/core.sh && source /tmp/lfs-scripts/pkg.sh && _strip_destdir '$chroot_destdir' '$pkg' && "
  # create package inside chroot tmp location and then copy to host PACKAGE_OUTPUT
  pack_cmd+="mkdir -p /tmp/packages && cd $chroot_destdir && if command -v zstd >/dev/null 2>&1; then tar -C '$chroot_destdir' -cf - . | zstd -19 -T0 -o /tmp/packages/${pkg}-${version}-lfs.tar.zst; else tar -C '$chroot_destdir' -cf - . | xz -9e -c > /tmp/packages/${pkg}-${version}-lfs.tar.xz; fi && echo /tmp/packages/${pkg}-${version}-lfs.*"

  local res
  res=$(_chroot_run "$pack_cmd" | sed -n '1,1p' || true)
  # copy package from chroot tmp to host PACKAGE_OUTPUT
  if [[ -z "$res" ]]; then
    die "packing inside chroot failed for $pkg"
  fi
  # find on LFS tmp path
  local host_tmp_pkg
  host_tmp_pkg=$(ls -1 "$LFS/tmp/packages" 2>/dev/null | grep "^${pkg}-${version}-lfs\." | head -n1 || true)
  if [[ -n "$host_tmp_pkg" ]]; then
    mv "$LFS/tmp/packages/$host_tmp_pkg" "$PACKAGE_OUTPUT/"
    info "moved package to $PACKAGE_OUTPUT/$host_tmp_pkg"
    echo "$PACKAGE_OUTPUT/$host_tmp_pkg"
  else
    # try to list any package file under LFS/tmp/packages
    host_tmp_pkg=$(find "$LFS/tmp/packages" -type f -name "${pkg}-${version}-lfs.*" | head -n1 || true)
    if [[ -n "$host_tmp_pkg" ]]; then
      mv "$host_tmp_pkg" "$PACKAGE_OUTPUT/"
      info "moved package to $PACKAGE_OUTPUT/$(basename "$host_tmp_pkg")"
      echo "$PACKAGE_OUTPUT/$(basename "$host_tmp_pkg")"
    else
      die "could not locate packaged file inside chroot for $pkg"
    fi
  fi
}

# high-level build flow for a single package
build_pkg() {
  local pkg="$1"
  info "===> Build requested: $pkg"
  acquire_lock "build-$pkg" || die "could not acquire lock for $pkg"

  # 1) fetch & unpack on host
  local src_host
  src_host=$("$SCRIPTDIR/pkg.sh" unpack "$pkg") || { error "unpack failed"; release_lock "build-$pkg"; return 1; }

  # determine version
  local version
  version=$(recipe_var "$pkg" version || true)
  if [[ -z "$version" ]]; then version=$(date +%s); fi

  # 2) copy scripts into chroot and sync source to chroot
  _copy_scripts_to_chroot
  local chroot_src_dir
  chroot_src_dir=$(_prepare_chroot_workdir "$pkg" "$version" "$src_host")

  # 3) build/install inside chroot (as BUILD_USER)
  if ! _build_in_chroot "$pkg" "$version" "$chroot_src_dir"; then
    error "in-chroot build failed for $pkg"
    # attempt rollback from any backup produced earlier
    attempt_rollback_from_backup "${PACKAGE_OUTPUT}/${pkg}-${version}-lfs.tar.zst" || true
    release_lock "build-$pkg"
    return 1
  fi

  # 4) strip + pack inside chroot and move package to host
  local pkgfile
  pkgfile=$(_strip_and_pack_in_chroot "$pkg" "$version") || { error "pack failed"; release_lock "build-$pkg"; return 1; }

  # 5) install packaged file atomically into LFS
  if ! "$SCRIPTDIR/pkg.sh" install-pkg "$pkgfile"; then
    error "install of package failed; attempting rollback"
    attempt_rollback_from_backup "$pkgfile" || warn "rollback failed for $pkg"
    release_lock "build-$pkg"
    return 1
  fi

  # 6) run verification if provided in recipe (inside chroot)
  source_recipe "$pkg"
  if declare -f verify >/dev/null 2>&1; then
    info "running recipe verify() inside chroot for $pkg"
    if ! _chroot_run "cd /build/${pkg}-${version}/src && source /tmp/lfs-scripts/recipes/$pkg.recipe && verify"; then
      error "verify() failed for $pkg; performing rollback"
      attempt_rollback_from_backup "$pkgfile" || warn "rollback failed"
      release_lock "build-$pkg"
      return 1
    fi
  fi

  info "Build and install finished for $pkg"
  release_lock "build-$pkg"
}

# update-all: improved to use topo-sort from core.sh
update_all() {
  local parallel=${1:-1}
  info "Starting update-all with parallel=$parallel"
  acquire_lock update-all || die "another update-all is running"
  # collect packages
  mapfile -t allpkgs < <(ls -1 "$SCRIPTDIR/recipes" | sed 's/\.recipe$//')

  # compute order using topo-sort helper from core.sh
  mapfile -t ordered < <(_topo_sort "${allpkgs[@]}") || die "dependency cycle detected; aborting update-all"

  info "build order determined: ${ordered[*]}"

  # build in order allowing parallelism for independent packages
  for pkg in "${ordered[@]}"; do
    build_pkg "$pkg" &
    # throttle
    while [[ $(jobs -r | wc -l) -ge $parallel ]]; do sleep 1; done
  done
  wait
  release_lock update-all
}

# upgrade single package
upgrade_pkg() {
  local pkg="$1"
  info "Upgrading package: $pkg"
  build_pkg "$pkg"
}

# CLI
if [[ $# -lt 1 ]]; then _usage; exit 1; fi
case "$1" in
  build)
    shift
    if [[ "$1" == "--pkg" ]]; then
      build_pkg "$2"
    elif [[ "$1" == "--group" ]]; then
      local groupfile="$SCRIPTDIR/recipes/groups/$2.list"
      if [[ ! -f "$groupfile" ]]; then die "group not found: $2"; fi
      mapfile -t gpkgs < "$groupfile"
      for p in "${gpkgs[@]}"; do build_pkg "$p"; done
    elif [[ "$1" == "--stage" ]]; then
      case "$2" in
        bootstrap)
          mapfile -t stagepkgs < "$SCRIPTDIR/recipes/stages/bootstrap.list"
          for p in "${stagepkgs[@]}"; do build_pkg "$p"; done
          ;;
        base)
          mapfile -t stagepkgs < "$SCRIPTDIR/recipes/stages/base.list"
          for p in "${stagepkgs[@]}"; do build_pkg "$p"; done
          ;;
        blfs)
          mapfile -t stagepkgs < "$SCRIPTDIR/recipes/stages/blfs.list"
          for p in "${stagepkgs[@]}"; do build_pkg "$p"; done
          ;;
        *) die "unknown stage: $2" ;;
      esac
    else
      _usage; exit 1
    fi
    ;;
  update-all)
    PARALLEL=${2:-$PARALLEL}
    update_all "$PARALLEL"
    ;;
  upgrade)
    shift
    if [[ "$1" == "--pkg" ]]; then
      upgrade_pkg "$2"
    else
      die "usage: $0 upgrade --pkg <pkg>"
    fi
    ;;
  --help|-h) _usage ;;
  *) _usage; exit 1 ;;
esac
