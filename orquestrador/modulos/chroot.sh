#!/usr/bin/env bash
# chroot.sh — Gestão de chroot seguro e bootstrap em /mnt/lfs
# Depende de: common.sh

set -euo pipefail

: "${LFS_RUNTIME:=/usr/local/lib/lfs}"
# shellcheck source=/usr/local/lib/lfs/common.sh
. "${LFS_RUNTIME}/common.sh"

#========================
# Config
#========================
: "${LFS_ROOT:=/mnt/lfs}"              # raiz do chroot (bootstrap)
: "${LFS_HOOKS_DIR:=${LFS_ETC}/hooks}" # hooks executados fora do chroot
: "${LFS_CHROOT_SHELL:=/bin/bash}"

#========================
# Hooks
#========================
run_hooks() {
  local name="$1" dir="${LFS_HOOKS_DIR}/${name}.d"
  [[ -d "${dir}" ]] || return 0
  log_info "Executando hooks: ${name}"
  local f
  # ordem lexicográfica
  for f in "${dir}/"*; do
    [[ -x "${f}" ]] || continue
    log_debug "Hook: ${f}"
    "${f}" || die 1 "Hook falhou: ${f}"
  done
}

#========================
# Layout /mnt/lfs
#========================
lfs_layout() {
  mkdir -p \
    "${LFS_ROOT}"/{bin,boot,etc,home,lib,lib64,media,mnt,opt,root,run,sbin,srv,tmp,usr,var} \
    "${LFS_ROOT}"/usr/{bin,lib,lib64,libexec,sbin,share,local} \
    "${LFS_ROOT}"/var/{cache,log,lib,spool,tmp} \
    "${LFS_ROOT}"/dev "${LFS_ROOT}"/proc "${LFS_ROOT}"/sys \
    "${LFS_ROOT}"/sources "${LFS_ROOT}"/tools "${LFS_ROOT}"/build "${LFS_ROOT}"/pkg
  chmod 1777 "${LFS_ROOT}/tmp" "${LFS_ROOT}/var/tmp"
  # Seed arquivos básicos
  [[ -f "${LFS_ROOT}/etc/hosts" ]] || cat >"${LFS_ROOT}/etc/hosts" <<'H'
127.0.0.1   localhost
::1         localhost
H
  # Copia resolv.conf para permitir rede dentro do chroot
  if [[ -f /etc/resolv.conf ]]; then
    install -D -m 0644 /etc/resolv.conf "${LFS_ROOT}/etc/resolv.conf"
  fi
  # Profile de ambiente minimalista dentro do chroot
  install -d -m 0755 "${LFS_ROOT}/etc/profile.d"
  cat > "${LFS_ROOT}/etc/profile.d/lfs.sh" <<'P'
export LC_ALL=C
export LANG=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/tools/bin
umask 022
P
  chmod 0644 "${LFS_ROOT}/etc/profile.d/lfs.sh"
}

#========================
# Montagens (binds) e desmontagens
#========================
_is_mounted() { mount | grep -qE " on $1 "; }

_mount_bind() {
  local src="$1" dst="$2" opts="${3:-rbind}"
  mkdir -p "${dst}"
  mount --make-rprivate / || true
  mount --"${opts}" "${src}" "${dst}"
}

mount_all() {
  assert_root
  bootstrap_runtime
  lfs_layout
  log_info "Montando binds no chroot: ${LFS_ROOT}"
  _is_mounted "${LFS_ROOT}" || mount -o bind "${LFS_ROOT}" "${LFS_ROOT}" || true

  _mount_bind /dev       "${LFS_ROOT}/dev"       rbind
  _mount_bind /dev/pts   "${LFS_ROOT}/dev/pts"   bind
  mount -t proc proc     "${LFS_ROOT}/proc"
  mount -t sysfs sysfs   "${LFS_ROOT}/sys"
  mount -t tmpfs tmpfs   "${LFS_ROOT}/run"

  log_ok "Binds montados."
}

umount_safe() {
  assert_root
  local target="$1"
  # desmonta na ordem inversa
  local points=(
    "${target}/run"
    "${target}/sys"
    "${target}/proc"
    "${target}/dev/pts"
    "${target}/dev"
    "${target}"
  )
  for p in "${points[@]}"; do
    if _is_mounted "${p}"; then
      if command -v fuser >/dev/null 2>&1; then
        if fuser -vm "${p}" >/dev/null 2>&1; then
          log_warn "Processos utilizando ${p}; tentativa de desmontagem forçada..."
        fi
      fi
      umount -R "${p}" 2>/dev/null || umount "${p}" 2>/dev/null || true
    fi
  done
}

umount_all() {
  assert_root
  log_info "Desmontando binds do chroot: ${LFS_ROOT}"
  umount_safe "${LFS_ROOT}"
  log_ok "Binds desmontados."
}

#========================
# Bootstrap
#========================
bootstrap_prepare() {
  assert_root
  bootstrap_runtime
  run_hooks "pre-bootstrap"
  lfs_layout
  log_ok "Layout preparado em ${LFS_ROOT}"
  run_hooks "post-bootstrap"
}

#========================
# Execução dentro do chroot
#========================
_chroot_env() {
  # Ambiente mínimo e determinístico
  env -i \
    HOME=/root \
    TERM="${TERM:-xterm-256color}" \
    PS1="(lfs) \u@\h:\w\$ " \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:/tools/bin" \
    LC_ALL=C LANG=C \
    LFS_ROOT="${LFS_ROOT}" \
    /usr/bin/env "$@"
}

chroot_exec() {
  assert_root
  bootstrap_runtime
  [[ -d "${LFS_ROOT}" ]] || die 2 "LFS_ROOT inexistente: ${LFS_ROOT}"
  mount | grep -q " on ${LFS_ROOT}/proc " || die 2 "Chroot não montado. Rode: lfsctl chroot mount"
  _copy_host_files
  _seed_shell_rc
  log_info "Executando no chroot: $*"
  chroot "${LFS_ROOT}" /usr/bin/env -i /bin/bash -lc "$*"
}

chroot_shell() {
  assert_root
  bootstrap_runtime
  mount | grep -q " on ${LFS_ROOT}/proc " || die 2 "Chroot não montado. Rode: lfsctl chroot mount"
  _copy_host_files
  _seed_shell_rc
  run_hooks "pre-enter"
  log_info "Entrando no chroot em ${LFS_ROOT} (shell interativo)"
  chroot "${LFS_ROOT}" /usr/bin/env -i /bin/bash --login
  log_ok "Saiu do chroot."
  run_hooks "post-leave"
}

_copy_host_files() {
  # Mantém DNS funcionando no chroot
  if [[ -f /etc/resolv.conf ]]; then
    install -m 0644 /etc/resolv.conf "${LFS_ROOT}/etc/resolv.conf"
  fi
}

_seed_shell_rc() {
  local rc="${LFS_ROOT}/root/.bashrc"
  if [[ ! -f "${rc}" ]]; then
    cat > "${rc}" <<'B'
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/tools/bin
export LC_ALL=C
umask 022
B
  fi
}

#========================
# Helper: fakeroot + DESTDIR
#========================
destdir_run() {
  local dest="$1"; shift || true
  [[ -n "${dest}" ]] || die 2 "Uso: destdir_run <DESTDIR> <comando...>"
  mkdir -p "${dest}"
  require_cmd fakeroot
  log_info "Executando com fakeroot e DESTDIR='${dest}': $*"
  # Executa o comando num shell, preservando códigos de saída
  fakeroot -- bash -lc "DESTDIR='${dest}' $*"
}

# Fim chroot.sh
