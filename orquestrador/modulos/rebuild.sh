#!/usr/bin/env bash
# rebuild.sh — Planejador/Executor de rebuild total/incremental com fingerprints
# Depende: common.sh, recipes.sh, builder.sh, packager.sh

set -euo pipefail

: "${LFS_RUNTIME:=/usr/local/lib/lfs}"
# shellcheck source=/usr/local/lib/lfs/common.sh
. "${LFS_RUNTIME}/common.sh"
# shellcheck source=/usr/local/lib/lfs/recipes.sh
. "${LFS_RUNTIME}/recipes.sh"
# shellcheck source=/usr/local/lib/lfs/builder.sh
. "${LFS_RUNTIME}/builder.sh"
# shellcheck source=/usr/local/lib/lfs/packager.sh
. "${LFS_RUNTIME}/packager.sh"

: "${LFS_INSTALLED_DIR:=/var/lib/lfs/db/installed}"
: "${LFS_MANIFESTS_DIR:=/var/lib/lfs/manifests}"
: "${LFS_PKG_DIR:=/var/lib/lfs/packages}"
: "${LFS_ROOT_INSTALL:=/mnt/lfs}"
: "${LFS_HOOKS_DIR:=/etc/lfs/hooks}"

rebuild_bootstrap() {
  bootstrap_runtime
  mkdir -p "${LFS_INSTALLED_DIR}" "${LFS_MANIFESTS_DIR}" "${LFS_PKG_DIR}" \
           "${LFS_HOOKS_DIR}/pre-world.d" "${LFS_HOOKS_DIR}/post-world.d" \
           "${LFS_HOOKS_DIR}/pre-package-rebuild.d" "${LFS_HOOKS_DIR}/post-package-rebuild.d"
}

# ----------------------------
# Fingerprints
# ----------------------------
toolchain_fingerprint() {
  # Versões básicas: gcc, ld, as, ar, ranlib, glibc (ldd)
  local gcc_v ld_v as_v glibc_v ar_v ran_v
  gcc_v="$(gcc -dumpfullversion -dumpversion 2>/dev/null || gcc --version 2>/dev/null | head -n1 || echo 'gcc?')"
  ld_v="$(ld --version 2>/dev/null | head -n1 || echo 'ld?')"
  as_v="$(as --version 2>/dev/null | head -n1 || echo 'as?')"
  ar_v="$(ar --version 2>/dev/null | head -n1 || echo 'ar?')"
  ran_v="$(ranlib --version 2>/dev/null | head -n1 || echo 'ranlib?')"
  glibc_v="$(ldd --version 2>/dev/null | head -n1 || getconf GNU_LIBC_VERSION 2>/dev/null || echo 'glibc?')"
  printf '%s\n' "${gcc_v}" "${ld_v}" "${as_v}" "${ar_v}" "${ran_v}" "${glibc_v}" | sha256sum | awk '{print $1}'
}

env_fingerprint() {
  # Hash de variáveis que impactam build
  local dump
  dump="$(printf 'CC=%s\nCXX=%s\nCFLAGS=%s\nCXXFLAGS=%s\nLDFLAGS=%s\nCPPFLAGS=%s\nPKG_CONFIG_PATH=%s\nPATH=%s\n' \
    "${CC:-cc}" "${CXX:-c++}" "${CFLAGS:-}" "${CXXFLAGS:-}" "${LDFLAGS:-}" "${CPPFLAGS:-}" "${PKG_CONFIG_PATH:-}" "${PATH:-}")"
  printf '%s' "${dump}" | sha256sum | awk '{print $1}'
}

_is_elf() { file -L "$1" 2>/dev/null | grep -q 'ELF'; }

abi_fingerprint_from_dir() {
  local root="$1"
  local tmp="$(mktemp)"
  # Para cada ELF, anexa SONAME e NEEDED (ordenado)
  while IFS= read -r -d '' f; do
    if _is_elf "$f"; then
      {
        echo "FILE: ${f#"${root}"}"
        readelf -d "$f" 2>/dev/null | grep -E '(SONAME|NEEDED)' | sed -E 's/ +//g' | sort
      } >> "${tmp}"
    fi
  done < <(find "${root}" -type f -print0)
  local fp; fp="$(sha256sum "${tmp}" | awk '{print $1}')"
  rm -f "${tmp}"
  echo "${fp}"
}

# ----------------------------
# Metadados: helpers
# ----------------------------
meta_get() { # meta_get <name> <key>
  local name="$1" key="$2" f="${LFS_INSTALLED_DIR}/${name}.meta"
  [[ -f "$f" ]] || return 1
  awk -F= -v K="$key" '$1==K{print $2}' "$f"
}

meta_set() { # meta_set <name> <key> <val>
  local name="$1" key="$2" val="$3" f="${LFS_INSTALLED_DIR}/${name}.meta"
  [[ -f "$f" ]] || return 1
  if grep -qE "^${key}=" "$f"; then
    sed -i -E "s|^${key}=.*|${key}=${val}|g" "$f"
  else
    echo "${key}=${val}" >> "$f"
  fi
}

installed_list() {
  for f in "${LFS_INSTALLED_DIR}"/*.meta; do
    [[ -f "$f" ]] || continue
    basename "${f}" .meta
  done
}

installed_deps() { # deps declarados da época do build
  local name="$1" f="${LFS_INSTALLED_DIR}/${name}.meta"
  [[ -f "$f" ]] || return 0
  awk -F= '$1=="deps"{print $2}' "$f" | tr ' ' '\n' | grep -vE '^\s*$' || true
}

installed_dep_versions() { # mapa dep=evr na hora do build
  local name="$1" f="${LFS_INSTALLED_DIR}/${name}.meta"
  [[ -f "$f" ]] || return 0
  awk -F= '$1=="dep_versions"{print $2}' "$f" | tr ' ' '\n' || true
}

# ----------------------------
# Grafo (instalados)
# ----------------------------
graph_installed_toposort() {
  # Kahn sobre metadados instalados
  declare -A indeg=(); declare -A adj=(); local nodes=()
  for n in $(installed_list); do nodes+=("$n"); indeg["$n"]=0; done
  for n in "${nodes[@]}"; do
    for d in $(installed_deps "$n"); do
      adj["$d"]+="${n} "
      (( indeg["$n"]++ ))
    done
  done
  local q=() out=()
  for n in "${nodes[@]}"; do (( indeg["$n"]==0 )) && q+=("$n"); done
  while ((${#q[@]})); do
    local v="${q[0]}"; q=("${q[@]:1}"); out+=("$v")
    for w in ${adj["$v"]:-}; do
      (( indeg["$w"]-- ))
      (( indeg["$w"]==0 )) && q+=("$w")
    done
  done
  if ((${#out[@]}!=${#nodes[@]})); then
    local cyc=()
    for n in "${nodes[@]}"; do (( indeg["$n"]>0 )) && cyc+=("$n"); done
    die 1 "Ciclo detectado entre instalados: ${cyc[*]}"
  fi
  printf '%s\n' "${out[@]}"
}

check_cycles_installed() { graph_installed_toposort >/dev/null; log_ok "Sem ciclos entre instalados."; }
check_cycles_recipes()   { # usa o resolvedor do builder
  local r all=()
  for r in $(find "${LFS_RECIPES_DIR}" "${LFS_RECIPES_SYS}" -type f -name '*.sh' 2>/dev/null | sed -E 's@.*/([^/]+)\.sh$@\1@' | sort -u); do
    all+=("$r")
  done
  printf '%s\n' "${all[@]}" | deps_graph >/dev/null
  log_ok "Sem ciclos entre receitas."
}

# ----------------------------
# Razões de rebuild
# ----------------------------
reason_toolchain_changed() {
  local global_fp_file="${LFS_DB_DIR}/toolchain.fp"
  local cur; cur="$(toolchain_fingerprint)"
  if [[ -f "${global_fp_file}" ]]; then
    local prev; prev="$(cat "${global_fp_file}")"
    [[ "${cur}" != "${prev}" ]]
  else
    # primeira execução grava e não força rebuild de tudo
    echo "${cur}" > "${global_fp_file}"
    return 1
  fi
}

reason_env_changed_pkg() {
  local name="$1"
  local old; old="$(meta_get "${name}" "env_fp" || echo "")"
  local cur; cur="$(env_fingerprint)"
  [[ -n "${old}" && "${old}" != "${cur}" ]]
}

reason_dep_upgraded_pkg() {
  local name="$1"
  local ev oldmap curmap d ev_inst
  # constrói mapa atual dep=evr
  declare -A CUR=()
  for d in $(installed_deps "${name}"); do
    ev_inst="$(meta_get "${d}" "evr" || true)"
    [[ -n "${ev_inst}" ]] && CUR["$d"]="${ev_inst}"
  done
  # compara com dep_versions do build
  local changed=0
  while read -r kv; do
    [[ -z "$kv" ]] && continue
    local dep="${kv%%=*}" ever="${kv#*=}"
    local now="${CUR[$dep]:-}"
    if [[ -n "${now}" && "${now}" != "${ever}" ]]; then
      changed=1; break
    fi
  done < <(installed_dep_versions "${name}")
  [[ ${changed} -eq 1 ]]
}

reason_abi_changed_pkg() {
  local name="$1"
  local old; old="$(meta_get "${name}" "abi_fp" || echo "")"
  local staged; staged="$(awk -F= '$1=="destdir"{print $2}' "${LFS_INSTALLED_DIR}/${name}.meta" 2>/dev/null || true)"
  local root="${staged:-${LFS_ROOT_INSTALL}}" # se não tem staged, calcula no root atual
  local dir; dir="${root}"
  local cur; cur="$(abi_fingerprint_from_dir "${dir}")"
  [[ -n "${old}" && "${old}" != "${cur}" ]]
}

# ----------------------------
# Plano de rebuild
# ----------------------------
rebuild_plan_world() {
  rebuild_bootstrap
  # Ordem topológica (instalados). Rebuild tudo.
  graph_installed_toposort
}

rebuild_plan_changed() {
  rebuild_bootstrap
  local name="$1"
  [[ -n "${name}" ]] || die 2 "Uso: rebuild_plan_changed <name>"
  # Todos que dependem (direta/indiretamente) de <name>, incluindo ele
  declare -A MARK=()
  MARK["$name"]=1
  local queue=("$name")
  # Grafo reverso (dependentes)
  declare -A REV=()
  local p
  for p in $(installed_list); do
    for d in $(installed_deps "$p"); do
      REV["$d"]+="${p} "
    done
  done
  while ((${#queue[@]})); do
    local v="${queue[0]}"; queue=("${queue[@]:1}")
    for w in ${REV["$v"]:-}; do
      if [[ -z "${MARK[$w]:-}" ]]; then MARK["$w"]=1; queue+=("$w"); fi
    done
  done
  # Em ordem topológica
  local ordered; ordered="$(graph_installed_toposort)"
  local x
  for x in ${ordered}; do [[ -n "${MARK[$x]:-}" ]] && echo "$x"; done
}

rebuild_plan_intelligent() {
  rebuild_bootstrap
  # Seleciona apenas os pacotes que precisam rebuild por alguma razão
  local need=()
  local p
  for p in $(installed_list); do
    if reason_toolchain_changed || reason_env_changed_pkg "$p" || reason_dep_upgraded_pkg "$p" || reason_abi_changed_pkg "$p"; then
      need+=("$p")
    fi
  done
  # Propaga dependentes dos marcados
  declare -A mark=()
  for n in "${need[@]}"; do mark["$n"]=1; done
  # Grafo reverso
  declare -A REV=()
  for p in $(installed_list); do
    for d in $(installed_deps "$p"); do
      REV["$d"]+="${p} "
    done
  done
  # BFS
  local queue=("${need[@]}")
  while ((${#queue[@]})); do
    local v="${queue[0]}"; queue=("${queue[@]:1}")
    for w in ${REV["$v"]:-}; do
      if [[ -z "${mark[$w]:-}" ]]; then mark["$w"]=1; queue+=("$w"); fi
    done
  done
  # Devolve em ordem topológica
  local ordered; ordered="$(graph_installed_toposort)"
  local x
  for x in ${ordered}; do [[ -n "${mark[$x]:-}" ]] && echo "$x"; done
}

# ----------------------------
# Execução do plano
# ----------------------------
_run_world_hooks() {
  local which="$1"
  local d="${LFS_HOOKS_DIR}/${which}.d"
  [[ -d "$d" ]] || return 0
  for f in "$d"/*; do [[ -x "$f" ]] && "$f" "$which" || true; done
}

_run_pkg_hooks() {
  local which="$1" name="$2"
  local d="${LFS_HOOKS_DIR}/${which}.d"
  [[ -d "$d" ]] || return 0
  for f in "$d"/*; do [[ -x "$f" ]] && "$f" "$name" || true; done
}

rebuild_run_plan() {
  rebuild_bootstrap
  local plan_file="$1" jobs="${2:-$(effective_jobs)}" chroot="${3:-0}" force="${4:-0}"
  [[ -f "${plan_file}" ]] || die 2 "Plano inexistente: ${plan_file}"

  _run_world_hooks "pre-world"
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    _run_pkg_hooks "pre-package-rebuild" "$pkg"
    # build_with_deps já cuida da ordem e locks; aqui usamos --rebuild e --force (para refazer mesmo instalado)
    build_with_deps "$pkg" "${jobs}" 1 "${chroot}" "${force}"
    _run_pkg_hooks "post-package-rebuild" "$pkg"
  done < "${plan_file}"
  _run_world_hooks "post-world"
}

# ----------------------------
# Persistência do toolchain FP
# ----------------------------
save_toolchain_fp() {
  local f="${LFS_DB_DIR}/toolchain.fp"
  echo "$(toolchain_fingerprint)" > "${f}"
  log_ok "Toolchain fingerprint salvo em ${f}"
}

# ----------------------------
# Exposição pública
# ----------------------------
export -f rebuild_bootstrap toolchain_fingerprint env_fingerprint abi_fingerprint_from_dir \
  check_cycles_installed check_cycles_recipes \
  rebuild_plan_world rebuild_plan_changed rebuild_plan_intelligent rebuild_run_plan save_toolchain_fp
