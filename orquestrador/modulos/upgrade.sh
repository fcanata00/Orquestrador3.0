#!/usr/bin/env bash
# upgrade.sh — Upgrade inteligente (rebuild) com rollback por pacote e delta diff
# Depende: common.sh, recipes.sh, builder.sh, packager.sh, rebuild.sh (para fingerprints)

set -euo pipefail

: "${LFS_RUNTIME:=/usr/local/lib/lfs}"
# shellcheck source=/usr/local/lib/lfs/common.sh
. "${LFS_RUNTIME}/common.sh"
# shellcheck source=/usr/local/lib/lfs/recipes.sh
. "${LFS_RUNTIME}/recipes.sh"
# shellcheck source=/usr/local/lib/lfs/builder.sh"
. "${LFS_RUNTIME}/builder.sh"
# shellcheck source=/usr/local/lib/lfs/packager.sh"
. "${LFS_RUNTIME}/packager.sh"
# shellcheck source=/usr/local/lib/lfs/rebuild.sh"
. "${LFS_RUNTIME}/rebuild.sh"

: "${LFS_DB_DIR:=/var/lib/lfs/db}"
: "${LFS_INSTALLED_DIR:=/var/lib/lfs/db/installed}"
: "${LFS_PKG_DIR:=/var/lib/lfs/packages}"
: "${LFS_MANIFESTS_DIR:=/var/lib/lfs/manifests}"
: "${LFS_ROOT_INSTALL:=/mnt/lfs}"
: "${LFS_HOOKS_DIR:=/etc/lfs/hooks}"
: "${LFS_HISTORY_DIR:=/var/lib/lfs/history}"
: "${LFS_ROLLBACK_DIR:=/var/lib/lfs/rollback}"
: "${LFS_DELTA_DIR:=/var/lib/lfs/delta}"

upgrade_bootstrap() {
  bootstrap_runtime
  mkdir -p "${LFS_HISTORY_DIR}" "${LFS_ROLLBACK_DIR}" "${LFS_DELTA_DIR}" \
           "${LFS_HOOKS_DIR}/pre-upgrade.d" "${LFS_HOOKS_DIR}/post-upgrade.d" \
           "${LFS_HOOKS_DIR}/pre-rollback.d" "${LFS_HOOKS_DIR}/post-rollback.d"
}

# ----------------------------
# Utils / metadados
# ----------------------------
meta_get() { local name="$1" key="$2" f="${LFS_INSTALLED_DIR}/${name}.meta"; [[ -f "$f" ]] || return 1; awk -F= -v K="$key" '$1==K{print $2}' "$f"; }
is_installed() { [[ -f "${LFS_INSTALLED_DIR}/${1}.meta" ]]; }

_current_evr() { meta_get "$1" "evr" || echo ""; }
_pkg_tar_for() { # _pkg_tar_for <name> <version> <release>
  echo "${LFS_PKG_DIR}/$1-$2-$3.tar.zst"
}
_manifest_path_for_evr() { # name evr
  echo "${LFS_MANIFESTS_DIR}/$1-$2.manifest"
}

# ----------------------------
# Delta diff entre manifests
# ----------------------------
_delta_generate() {
  local name="$1" old_m="$2" new_m="$3" out="$4"
  local tmpo tnew
  tmpo="$(mktemp)"; tnew="$(mktemp)"
  awk '{print $7 " " $6}' "${old_m}" | sort > "${tmpo}"   # path sha_old
  awk '{print $7 " " $6}' "${new_m}" | sort > "${tnew}"   # path sha_new

  local added removed changed unchanged
  added="$(comm -13 <(cut -d' ' -f1 "${tmpo}") <(cut -d' ' -f1 "${tnew}"))"
  removed="$(comm -23 <(cut -d' ' -f1 "${tmpo}") <(cut -d' ' -f1 "${tnew}"))"
  changed="$(join -j1 -o 1.1,1.2,2.2 -a1 -e '-' -t ' ' \
              <(sort -k1,1 "${tmpo}") <(sort -k1,1 "${tnew}") \
              | awk '$2!=$3 && $2!="-"{print $1" "$2" -> "$3}')"
  unchanged="$(join -j1 -o 1.1 -t ' ' <(sort -k1,1 "${tmpo}") <(sort -k1,1 "${tnew}") | awk 'NF>0')"

  {
    echo "# delta ${name}"
    echo "## added"
    [[ -n "${added}" ]] && echo "${added}" || echo "-"
    echo "## removed"
    [[ -n "${removed}" ]] && echo "${removed}" || echo "-"
    echo "## changed"
    [[ -n "${changed}" ]] && echo "${changed}" || echo "-"
    echo "## unchanged"
    [[ -n "${unchanged}" ]] && echo "${unchanged}" || echo "-"
  } > "${out}.tmp"
  mv -f "${out}.tmp" "${out}"
  rm -f "${tmpo}" "${tnew}"
}

# ----------------------------
# Rollback bundle (backup do estado atual do pacote)
# ----------------------------
_rollback_bundle_create() {
  local name="$1" old_evr="$2" root="${3:-${LFS_ROOT_INSTALL}}"
  local manifest="$(_manifest_path_for_evr "${name}" "${old_evr}")"
  [[ -f "${manifest}" ]] || die 2 "Manifesto do pacote atual não encontrado: ${manifest}"

  local dir="${LFS_ROLLBACK_DIR}/${name}/${old_evr}"
  mkdir -p "${dir}"
  # salva o manifest usado
  cp -f "${manifest}" "${dir}/manifest.old"

  # lista arquivos a salvar (f e l). diretórios não são necessários no bundle
  local listf; listf="$(mktemp)"
  awk '$4=="f" || $4=="l"{print $7}' "${manifest}" > "${listf}"

  local rb="${dir}/bundle.tar.zst"
  log_info "Criando rollback bundle: ${rb}"
  (
    cd "${root}"
    tar --posix --xattrs --acls --no-same-owner --numeric-owner -cf - -T "${listf}" \
      | zstd -T0 -19 -o "${rb}.tmp"
  )
  mv -f "${rb}.tmp" "${rb}"
  rm -f "${listf}"

  # histórico rápido
  echo "$(date -u +%FT%TZ) SAVE ${name} ${old_evr}" >> "${LFS_HISTORY_DIR}/${name}.log"
  echo "${rb}"
}

# ----------------------------
# Hooks helpers
# ----------------------------
_run_hooks_list() {
  local dir="$1"; shift
  [[ -d "${dir}" ]] || return 0
  local f
  for f in "${dir}/"*; do
    [[ -x "$f" ]] && "$f" "$@" || true
  done
}

_pre_upgrade_hooks()  { _run_hooks_list "${LFS_HOOKS_DIR}/pre-upgrade.d"  "$@"; }
_post_upgrade_hooks() { _run_hooks_list "${LFS_HOOKS_DIR}/post-upgrade.d" "$@"; }
_pre_rollback_hooks() { _run_hooks_list "${LFS_HOOKS_DIR}/pre-rollback.d" "$@"; }
_post_rollback_hooks(){ _run_hooks_list "${LFS_HOOKS_DIR}/post-rollback.d" "$@"; }

# ----------------------------
# Upgrade inteligente (rebuild from source)
# ----------------------------
upgrade_smart() {
  upgrade_bootstrap
  local name="$1" jobs="${2:-$(effective_jobs)}" use_chroot="${3:-0}" force="${4:-0}"
  recipe_load "${name}"
  local target_ver="${VERSION}"; local target_rel="${RELEASE:-1}"; local epoch="${EPOCH:-0}"
  local target_evr="${epoch}:${target_ver}-${target_rel}"

  local installed_evr; installed_evr="$(_current_evr "${name}" || true)"
  if [[ -n "${installed_evr}" ]]; then
    # compara EVR
    local cmp; cmp="$(cmp_evr "${target_evr}" "${installed_evr}")"
    if [[ "${cmp}" -le 0 && "${force}" -ne 1 ]]; then
      log_warn "Versão-alvo (${target_evr}) não é mais nova que a instalada (${installed_evr}). Use --force para refazer."
      return 0
    fi
  fi

  # Build + pacote novo
  log_info "Construindo ${name}-${target_ver}-${target_rel} (jobs=$(jobs_to_make "${jobs}"), chroot=${use_chroot})"
  build_with_deps "${name}" "${jobs}" 0 "${use_chroot}" "${force}"

  local new_pkg="${LFS_PKG_DIR}/${NAME}-${target_ver}-${target_rel}.tar.zst"
  [[ -f "${new_pkg}" ]] || die 2 "Pacote novo não encontrado: ${new_pkg}"
  local new_manifest="${LFS_MANIFESTS_DIR}/${NAME}-${epoch}:${target_ver}-${target_rel}.manifest"
  [[ -f "${new_manifest}" ]] || die 2 "Manifesto novo não encontrado: ${new_manifest}"

  # Se há versão instalada, gerar delta + rollback bundle ANTES de mexer
  local delta_out=""
  if [[ -n "${installed_evr}" ]]; then
    local old_manifest="$(_manifest_path_for_evr "${name}" "${installed_evr}")"
    [[ -f "${old_manifest}" ]] || die 2 "Manifesto antigo não encontrado: ${old_manifest}"
    local dd="${LFS_DELTA_DIR}/${name}/${installed_evr}__to__${epoch}:${target_ver}-${target_rel}.delta"
    mkdir -p "$(dirname "${dd}")"
    _delta_generate "${name}" "${old_manifest}" "${new_manifest}" "${dd}"
    delta_out="${dd}"
    log_info "Delta diff salvo: ${dd}"

    # Salva rollback
    _pre_upgrade_hooks "${name}" "${installed_evr}" "${epoch}:${target_ver}-${target_rel}" "${new_pkg}"
    local rb; rb="$(_rollback_bundle_create "${name}" "${installed_evr}" "${LFS_ROOT_INSTALL}")"
    log_info "Rollback bundle: ${rb}"
  else
    _pre_upgrade_hooks "${name}" "none" "${epoch}:${target_ver}-${target_rel}" "${new_pkg}"
  fi

  # Executa upgrade real (uninstall atual -> install novo)
  if [[ -n "${installed_evr}" ]]; then
    package_uninstall "${name}" "${LFS_ROOT_INSTALL}" 1
  fi
  package_install "${new_pkg}" "${LFS_ROOT_INSTALL}"

  # Atualiza histórico
  echo "$(date -u +%FT%TZ) UPGRADE ${name} ${installed_evr:-none} -> ${epoch}:${target_ver}-${target_rel}" >> "${LFS_HISTORY_DIR}/${name}.log"
  _post_upgrade_hooks "${name}" "${installed_evr:-none}" "${epoch}:${target_ver}-${target_rel}" "${new_pkg}" "${delta_out:-}"

  log_ok "Upgrade concluído: ${name} -> ${epoch}:${target_ver}-${target_rel}"
  [[ -n "${delta_out}" ]] && echo "delta: ${delta_out}"
}

# ----------------------------
# Rollback (para EVR anterior ou específico)
# ----------------------------
rollback_package() {
  upgrade_bootstrap
  local name="$1" to_evr="${2:-prev}" root="${3:-${LFS_ROOT_INSTALL}}" dry="${4:-0}"

  local current_evr; current_evr="$(_current_evr "${name}" || true)"
  [[ -n "${current_evr}" ]] || die 2 "Pacote não está instalado: ${name}"

  local target_evr=""
  if [[ "${to_evr}" == "prev" ]]; then
    # pega o penúltimo da linha do tempo
    local hist="${LFS_HISTORY_DIR}/${name}.log"
    [[ -f "${hist}" ]] || die 2 "Histórico ausente: ${hist}"
    # procura última linha UPGRADE e usa o EVR anterior
    target_evr="$(tac "${hist}" | awk '/UPGRADE/ {print $4; exit}')" || true
    [[ -n "${target_evr}" ]] || die 2 "Não encontrei EVR anterior no histórico."
  else
    target_evr="${to_evr}"
  fi

  if [[ "${dry}" -eq 1 ]]; then
    echo "DRY-RUN: rollback ${name} ${current_evr} -> ${target_evr}"
    return 0
  fi

  _pre_rollback_hooks "${name}" "${current_evr}" "${target_evr}"

  # Estratégia: uninstall atual -> instalar pacote do EVR alvo; se tarball do EVR alvo não existir, restaura bundle.
  package_uninstall "${name}" "${root}" 1

  local ver rel epoch
  epoch="${target_evr%%:*}"; local rest="${target_evr#*:}"
  ver="${rest%-*}"; rel="${rest##*-}"
  local tar_target; tar_target="$(_pkg_tar_for "${name}" "${ver}" "${rel}")"

  if [[ -f "${tar_target}" ]]; then
    package_install "${tar_target}" "${root}"
    log_ok "Rollback via pacote reinstalado: ${tar_target}"
  else
    # fallback: restaurar bundle salvo
    local rb="${LFS_ROLLBACK_DIR}/${name}/${target_evr}/bundle.tar.zst"
    [[ -f "${rb}" ]] || die 2 "Nem pacote nem rollback bundle encontrados para ${name} ${target_evr}"
    log_warn "Pacote alvo não encontrado; restaurando rollback bundle (arquivos)."
    zstd -d -c "${rb}" | tar -C "${root}" --numeric-owner --same-permissions -xf -
    # registrar meta mínima (mantemos manifest antigo se existir)
    local mani="$(_manifest_path_for_evr "${name}" "${target_evr}")"
    [[ -f "${mani}" ]] && _register_install_meta_min "${name}" "${target_evr}" "${root}" "${mani}"
    log_ok "Rollback via bundle restaurado."
  fi

  echo "$(date -u +%FT%TZ) ROLLBACK ${name} ${current_evr} -> ${target_evr}" >> "${LFS_HISTORY_DIR}/${name}.log"
  _post_rollback_hooks "${name}" "${current_evr}" "${target_evr}"
}

_register_install_meta_min() {
  local name="$1" evr="$2" root="$3" manifest="$4"
  local meta="${LFS_INSTALLED_DIR}/${name}.meta"
  {
    echo "name=${name}"
    echo "evr=${evr}"
    echo "root=${root}"
    echo "package="              # desconhecido (bundle)
    echo "manifest=${manifest}"
    echo "install_time=$(date -u +%s)"
  } > "${meta}.tmp"
  mv -f "${meta}.tmp" "${meta}"
}

# ----------------------------
# Consultas
# ----------------------------
delta_show() {
  local name="$1" from_to="${2:-latest}"
  if [[ "${from_to}" == "latest" ]]; then
    # pega o último delta registrado para o pacote
    local d; d="$(ls -1 "${LFS_DELTA_DIR}/${name}"/ 2>/dev/null | tail -n1 || true)"
    [[ -n "${d}" ]] || die 2 "Sem delta registrado para ${name}"
    cat "${LFS_DELTA_DIR}/${name}/${d}"
  else
    local f="${LFS_DELTA_DIR}/${name}/${from_to}.delta"
    [[ -f "${f}" ]] || die 2 "Delta não encontrado: ${f}"
    cat "${f}"
  fi
}

history_show() {
  local name="$1"
  local hist="${LFS_HISTORY_DIR}/${name}.log"
  [[ -f "${hist}" ]] || die 2 "Sem histórico para ${name}"
  cat "${hist}"
}

export -f upgrade_bootstrap upgrade_smart rollback_package delta_show history_show
