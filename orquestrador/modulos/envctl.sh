#!/usr/bin/env bash
# envctl.sh
# Controle do ambiente LFS: init, mount, enter, umount, check-host
# Requer core.sh no mesmo diretório ou SCRIPTDIR apontando para ele.

set -euo pipefail
IFS=$'\n\t'

SCRIPTDIR="${SCRIPTDIR:-$(dirname "${BASH_SOURCE[0]}")}"
# shellcheck source=core.sh
source "$SCRIPTDIR/core.sh"

# default LFS dir (can be overridden by exporting LFS before calling)
LFS="${LFS:-/mnt/lfs}"
BUILD_USER="${BUILD_USER:-lfsbuilder}"
PARALLEL_MAKE="${PARALLEL_MAKE:-$(nproc)}"

# mount flags
MOUNT_OPTS_FS="nodev,nosuid"
MOUNT_OPTS_EXEC="noexec"

# helper funcs
_usage() {
  cat <<EOF
Usage: $0 <command> [options]
Commands:
  init            Create LFS directories and optional build user
  mount           Mount /proc /sys /dev /dev/pts /run into \$LFS
  umount          Unmount mounts made by mount
  enter [cmd]     Enter chroot as BUILD_USER (or run command)
  check-host      Detect host and print package install hints
  status          Show mount and user status

Environment variables that can be set before calling:
  LFS (default /mnt/lfs)
  BUILD_USER (default lfsbuilder)
EOF
}

# Ensure LFS paths exist
_init_dirs() {
  mkdir -p "$LFS" || die "cannot create LFS root $LFS"
  for d in sources build tools packages logs manifests buildlogs snapshots hooks recipes patches; do
    mkdir -p "$LFS/$d"
  done
  chown root:root "$LFS"
  chmod 0755 "$LFS"
}

_create_build_user() {
  if id -u "$BUILD_USER" >/dev/null 2>&1; then
    info "build user $BUILD_USER exists"
    return 0
  fi

  if [[ $(id -u) -ne 0 ]]; then
    warn "must be root to create build user; please create user $BUILD_USER manually"
    return 1
  fi

  info "creating build user $BUILD_USER"
  useradd -m -s /bin/bash -U "$BUILD_USER" || die "failed to create user $BUILD_USER"
  passwd -l "$BUILD_USER" || true
}

# mount helper with options detection
_mount_one() {
  local src="$1" dest="$2" opts_add="${3:-}" force_ro="${4:-0}"
  mkdir -p "$dest"
  if mountpoint -q "$dest"; then
    info "$dest already mounted"
    return 0
  fi
  local opts="$MOUNT_OPTS_FS"
  if [[ "$force_ro" -eq 1 ]]; then
    opts+=",ro"
  fi
  if [[ -n "$opts_add" ]]; then
    opts+=","$opts_add
  fi
  # try mount with bind then remount to apply flags
  run_and_log mount -- "$src" "$dest" || die "mount $src -> $dest failed"
  if ! mount -o remount,"$opts" "$dest" >/dev/null 2>&1; then
    info "remount with flags failed for $dest; leaving as-is"
  fi
}

# public commands
cmd_init() {
  acquire_lock init || die "another init running"
  _init_dirs
  if [[ "$CREATE_BUILD_USER_IF_MISSING" != "0" ]]; then
    _create_build_user || warn "create user recommended"
  fi
  # ensure perms for sources cache and packages
  chown -R root:root "$LFS"
  chmod -R u+rwX,go-rwx "$LFS/sources" || true
  mkdir -p "$LFS/sources/cache"
  info "LFS init complete at $LFS"
  release_lock init
}

cmd_mount() {
  acquire_lock mount || die "another mount action running"
  mkdir -p "$LFS/dev" "$LFS/proc" "$LFS/sys" "$LFS/run" "$LFS/dev/pts"

  # bind mount /dev
  _mount_one "/dev" "$LFS/dev" "" 0
  # dev pts
  _mount_one "/dev/pts" "$LFS/dev/pts" "" 0 || true
  # proc and sys
  if ! mountpoint -q "$LFS/proc"; then
    run_and_log mount --types proc /proc "$LFS/proc"
  fi
  if ! mountpoint -q "$LFS/sys"; then
    run_and_log mount --types sysfs /sys "$LFS/sys"
  fi
  # run
  if ! mountpoint -q "$LFS/run"; then
    mkdir -p "$LFS/run"
    run_and_log mount --bind /run "$LFS/run"
  fi
  # pseudo-filesystems done

  # prepare /tools inside chroot
  mkdir -p "$LFS/tools"
  info "mounted proc/sys/dev/run into $LFS"
  release_lock mount
}

cmd_umount() {
  acquire_lock mount || die "another mount action running"
  # Attempt to unmount in reverse order
  local -a targets=("$LFS/run" "$LFS/sys" "$LFS/proc" "$LFS/dev/pts" "$LFS/dev")
  for t in "${targets[@]}"; do
    if mountpoint -q "$t"; then
      info "attempting to unmount $t"
      set +e
      umount -l "$t" 2>/dev/null || umount "$t" 2>/dev/null || true
      set -e
    else
      info "$t not mounted"
    fi
  done
  release_lock mount
}

cmd_enter() {
  local cmd
  cmd="$*"
  if [[ -z "$cmd" ]]; then
    cmd="/bin/bash"
  fi
  if ! mountpoint -q "$LFS/proc"; then
    warn "LFS not mounted; mounting now"
    cmd_mount
  fi

  # Use chroot and runuser to drop to BUILD_USER
  if id -u "$BUILD_USER" >/dev/null 2>&1; then
    info "entering chroot as $BUILD_USER: $cmd"
    run_and_log chroot "$LFS" /usr/sbin/runuser -l "$BUILD_USER" -c "$cmd"
  else
    info "entering chroot as root: $cmd"
    run_and_log chroot "$LFS" "$cmd"
  fi
}

cmd_check_host() {
  info "Detecting host distribution"
  if command -v emerge >/dev/null 2>&1; then
    echo "Host appears to be Gentoo (emerge found). Suggested packages to install (as root):"
    echo "  emerge --ask sys-devel/gcc sys-devel/binutils app-arch/xz net-misc/wget dev-vcs/git dev-util/curl dev-util/rsync sys-apps/busybox"
  elif [[ -f /etc/venom-release || -f /etc/venom_version ]]; then
    echo "Host appears to be Venom Linux. Suggested: ensure build essentials exist (gcc, make, xz, tar, git, wget/curl)"
    echo "Venom is source-based; use your ports/scratchpkg tooling to install base tools"
  elif command -v apt >/dev/null 2>&1; then
    echo "Detected apt: 'sudo apt install build-essential xz-utils wget curl git rsync'"
  elif command -v dnf >/dev/null 2>&1; then
    echo "Detected dnf: 'sudo dnf install @development-tools xz wget curl git rsync'"
  else
    echo "Host detection inconclusive. Ensure you have: gcc, make, xz, tar, git, wget/curl, rsync, perl, python3."
  fi
}

cmd_status() {
  echo "LFS: $LFS"
  echo "BUILD_USER: $BUILD_USER"
  echo "Mounts:"
  mount | grep "$LFS" || true
  echo "Locks:"
  ls -la "$LOCK_DIR" || true
}

# dispatch
if [[ $# -lt 1 ]]; then
  _usage; exit 1
fi
cmd="$1"; shift
case "$cmd" in
  init) CREATE_BUILD_USER_IF_MISSING=1; cmd_init "$@" ;;
  mount) cmd_mount "$@" ;;
  umount) cmd_umount "$@" ;;
  enter) cmd_enter "$@" ;;
  check-host) cmd_check_host "$@" ;;
  status) cmd_status "$@" ;;
  -h|--help) _usage ;;
  *) _usage; exit 1 ;;
esac
