#!/usr/bin/env bash
# builder.sh — Grafo de dependências, fetch, extract, patch e build DESTDIR
# Depende: common.sh, downloader.sh, recipes.sh, (opcional) chroot.sh

set -euo pipefail

: "${LFS_RUNTIME:=/usr/local/lib/lfs}"
# shellcheck source=/usr/local/lib/lfs/common.sh
. "${LFS_RUNTIME}/packager.sh"
# shellcheck source=/usr/local/lib/lfs/rebuild.sh
. "${LFS_RUNTIME}/rebuild.sh"
# shellcheck source=/usr/local/lib/lfs/packager.sh
. "${LFS_RUNTIME}/common.sh"
# shellcheck source=/usr/local/lib/lfs/downloader.sh
. "${LFS_RUNTIME}/downloader.sh"
# shellcheck source=/usr/local/lib/lfs/recipes.sh
. "${LFS_RUNTIME}/recipes.sh"
# (chroot.sh só é usado se --chroot for pedido no CLI)

: "${LFS_BUILDROOT:=/var/lib/lfs/build}"          # work-area fora do chroot por padrão
: "${LFS_STAGING:=/mnt/lfs/pkg}"                  # DESTDIR padrão (dentro de /mnt/lfs para bootstrap)
: "${LFS_HOOKS_DIR:=${LFS_ETC}/hooks}"            # hooks globais

builder_bootstrap() {
  recipes_bootstrap
  dl_bootstrap
  mkdir -p "${LFS_BUILDROOT}" "${LFS_STAGING}" "${LFS_DB_DIR}/installed"
}

#-----------------------------
# Hooks por estágio
#-----------------------------
_run_stage_hooks() {
  local stage="$1" name="$2" ver="$3"
  local d="${LFS_HOOKS_DIR}/${stage}.d"
  [[ -d "${d}" ]] || return 0
  log_info "Hooks (${stage}) para ${name}-${ver}"
  local f
  for f in "${d}/"*; do
    [[ -x "${f}" ]] || continue
    "${f}" "${name}" "${ver}" || die 1 "Hook falhou: ${f}"
  done
}

#-----------------------------
# Grafo de dependências (Kahn)
#-----------------------------
_resolve_graph() {
  # Entrada: nomes solicitados na stdin
  # Saída: ordem topológica (um nome por linha)
  local names=()
  while IFS= read -r n; do [[ -n "$n" ]] && names+=("$n"); done
  # Constrói arestas e conjunto de nós
  declare -A indeg=()
  declare -A adj=()
  declare -A seen=()
  local all=()

  _add_node() { local k="$1"; if [[ -z "${seen[$k]:-}" ]]; then seen["$k"]=1; all+=("$k"); indeg["$k"]=0; fi; }

  _add_edge() { local a="$1" b="$2"; # a -> b (a depende de b? nós queremos b antes de a)
    # Aqui vamos usar: pacote -> seus dependentes? Para Kahn: indeg[dep]++ se houver aresta dep -> pkg
    # adotar: b -> a (b é dependência de a)
    adj["$b"]+="${a} "; (( indeg["$a"]++ ))
  }

  # Explora recursivamente
  local work=("${names[@]}")
  local i
  while [[ ${#work[@]} -gt 0 ]]; do
    local x="${work[0]}"; work=("${work[@]:1}")
    _add_node "$x"
    # pega deps
    local deps
    deps="$(recipe_deps_all "$x" || true)"
    local d
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      _add_node "$d"
      _add_edge "$x" "$d"
      # navega
      if [[ -z "${seen[$d]:-}" ]]; then
        work+=("$d")
      fi
    done <<< "$deps"
  done

  # Kahn
  local q=()
  for n in "${all[@]}"; do
    if [[ ${indeg[$n]:-0} -eq 0 ]]; then q+=("$n"); fi
  done

  local out=()
  while [[ ${#q[@]} -gt 0 ]]; do
    local v="${q[0]}"; q=("${q[@]:1}")
    out+=("$v")
    for w in ${adj["$v"]:-}; do
      (( indeg["$w"]-- ))
      if [[ ${indeg["$w"]} -eq 0 ]]; then q+=("$w"); fi
    done
  done

  if [[ ${#out[@]} -ne ${#all[@]} ]]; then
    # ciclo detectado — encontra nós com indeg>0
    local cyc=()
    for n in "${all[@]}"; do
      if [[ ${indeg[$n]:-0} -gt 0 ]]; then cyc+=("$n"); fi
    done
    die 1 "Ciclo de dependências detectado: ${cyc[*]}"
  fi

  printf '%s\n' "${out[@]}"
}

deps_graph() {
  builder_bootstrap
  printf '%s\n' "$@" | _resolve_graph
}

deps_tree() {
  builder_bootstrap
  local name="$1"
  _print_tree() {
    local pkg="$1" prefix="$2"
    echo "${prefix}${pkg}"
    local d
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      _print_tree "$d" "${prefix}  "
    done < <(recipe_deps_all "$pkg")
  }
  _print_tree "${name}" ""
}

#-----------------------------
# Fetch fontes & patches
#-----------------------------
_fetch_sources_for() {
  local name="$1"
  recipe_load "${name}"
  log_info "Fetch sources: ${NAME}-${VERSION}"
  # Tarballs/arquivos
  local i
  for (( i=0; i<${#SOURCE[@]:-0}; i++ )); do
    local url="${SOURCE[$i]}" sha="${SHA256[$i]}"
    [[ -n "${url:-}" && -n "${sha:-}" ]] || continue
    dl_fetch_one "" "${url}" "${sha}" "" "${LFS_CACHE}/sources" >/dev/null
  done
  # Patches
  for (( i=0; i<${#PATCHES[@]:-0}; i++ )); do
    local purl="${PATCHES[$i]}" psha="${PATCHES_SHA256[$i]}"
    [[ -n "${purl:-}" && -n "${psha:-}" ]] || continue
    dl_fetch_one "" "${purl}" "${psha}" "" "${LFS_CACHE}/sources" >/dev/null
  done
  # Git (gera tar.zst reprodutível)
  if [[ -n "${GIT_URL}" && -n "${GIT_REF}" ]]; then
    dl_git_archive --url "${GIT_URL}" --ref "${GIT_REF}" --name "${NAME}" --outdir "${LFS_CACHE}/tarballs" >/dev/null
  fi
  _run_stage_hooks "post-fetch" "${NAME}" "${VERSION}"
}

#-----------------------------
# Extrai para diretório de build
#-----------------------------
_extract_to_builddir() {
  local name="$1" bdir="$2"
  recipe_load "${name}"
  rm -rf "${bdir}"
  mkdir -p "${bdir}"
  local extracted=0

  # Extrai primeira fonte como diretório principal
  if [[ -n "${GIT_URL}" && -n "${GIT_REF}" ]]; then
    local tarball
    tarball="$(ls -1 "${LFS_CACHE}/tarballs/${NAME}-"*.git.tar.zst 2>/dev/null | head -n1 || true)"
    [[ -n "${tarball}" ]] || die 1 "Tarball git não encontrado para ${NAME}"
    zstd -d -c "${tarball}" | tar -x -C "${bdir}"
    extracted=1
  fi

  local i
  for (( i=0; i<${#SOURCE[@]:-0}; i++ )); do
    local sfile="${LFS_CACHE}/sources/$(basename -- "${SOURCE[$i]}")"
    [[ -f "${sfile}" ]] || die 1 "Source ausente no cache: ${sfile}"
    # Detecta tipo
    case "${sfile}" in
      *.tar.zst)  zstd -d -c "${sfile}" | tar -x -C "${bdir}"; extracted=1;;
      *.tar.xz)   tar -xJf "${sfile}" -C "${bdir}"; extracted=1;;
      *.tar.gz|*.tgz) tar -xzf "${sfile}" -C "${bdir}"; extracted=1;;
      *.tar.bz2)  tar -xjf "${sfile}" -C "${bdir}"; extracted=1;;
      *.zip)      unzip -q "${sfile}" -d "${bdir}"; extracted=1;;
      *)          # arquivo solto, só copia
                  install -D -m 0644 "${sfile}" "${bdir}/$(basename -- "${sfile}")";;
    esac
  done
  [[ ${extracted} -eq 1 ]] || log_warn "Nenhum tarball extraído para ${name}; pode ser receita só de arquivo único."
}

#-----------------------------
# Aplica patches -p1
#-----------------------------
_apply_patches() {
  local name="$1" srcdir="$2"
  recipe_load "${name}"
  [[ ${#PATCHES[@]:-0} -gt 0 ]] || return 0
  _run_stage_hooks "pre-patch" "${NAME}" "${VERSION}"
  local i
  for (( i=0; i<${#PATCHES[@]}; i++ )); do
    local pfile="${LFS_CACHE}/sources/$(basename -- "${PATCHES[$i]}")"
    [[ -f "${pfile}" ]] || die 1 "Patch ausente: ${pfile}"
    ( cd "${srcdir}" && patch -p1 --input "${pfile}" )
  done
  _run_stage_hooks "post-patch" "${NAME}" "${VERSION}"
}

#-----------------------------
# Executa estágios prepare/build/install
#-----------------------------
_run_stage() {
  local name="$1" stage="$2" srcdir="$3" destdir="$4" jobs="$5"
  recipe_load "${name}"

  local has=0
  case "${stage}" in
    prepare) has="${HAS_PREPARE:-0}" ;;
    build)   has="${HAS_BUILD:-0}" ;;
    install) has="${HAS_INSTALL:-0}" ;;
  esac

  # Variáveis padrão exportadas às receitas
  export NAME VERSION EPOCH RELEASE
  export DESTDIR="${destdir}"
  export JOBS="${jobs}"
  export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

  if [[ "${has}" -eq 1 ]]; then
    _run_stage_hooks "pre-${stage}" "${NAME}" "${VERSION}"
    ( cd "${srcdir}" && bash -lc "${stage}" )
    _run_stage_hooks "post-${stage}" "${NAME}" "${VERSION}"
  else
    # Defaults sensatos se função não existe
    case "${stage}" in
      prepare) : ;;
      build)
        ( cd "${srcdir}" && \
          ( [[ -x configure ]] && ./configure --prefix=/usr || true ) && \
          make -j"${jobs}" )
        ;;
      install)
        ( cd "${srcdir}" && destdir_run "${destdir}" "make install" )
        ;;
    esac
  fi
}

#-----------------------------
# Metadados de build/instalação
#-----------------------------
_write_meta() {
  local name="$1" destdir="$2"
  recipe_load "${name}"

  # fingerprints
  local envfp; envfp="$(env_fingerprint)"
  local abifp; abifp="$(abi_fingerprint_from_dir "${destdir}")"
  local toolfp; toolfp="$(toolchain_fingerprint)"

  # versões das dependências no momento do build
  local depv=()
  local d ev
  for d in ${DEPS[*]:-}; do
    ev="$(is_installed "$d" && awk -F= '$1=="evr"{print $2}' "${LFS_DB_DIR}/installed/${d}.meta" || echo "")"
    [[ -n "${ev}" ]] && depv+=("${d}=${ev}")
  done

  local mdir="${LFS_DB_DIR}/installed"
  mkdir -p "${mdir}"
  local meta="${mdir}/${NAME}.meta"
  {
    echo "name=${NAME}"
    echo "version=${VERSION}"
    echo "epoch=${EPOCH}"
    echo "release=${RELEASE}"
    echo "evr=${EPOCH}:${VERSION}-${RELEASE}"
    echo "build_time=$(date -u +%s)"
    echo "deps=${DEPS[*]:-}"
    echo "build_deps=${BUILD_DEPS[*]:-}"
    echo "dep_versions=${depv[*]:-}"
    echo "destdir=${destdir}"
    echo "env_fp=${envfp}"
    echo "abi_fp=${abifp}"
    echo "toolchain_fp=${toolfp}"
  } > "${meta}.tmp"
  mv -f "${meta}.tmp" "${meta}"
  log_ok "Metadados gravados: ${meta}"
}
#-----------------------------
# Build único (com fetch/extract/patch/run)
#-----------------------------
build_one() {
  local name="$1" jobs="$2" rebuild="$3" use_chroot="$4"
  builder_bootstrap
  recipe_lint "${name}"

  if is_installed "${name}" && [[ "${rebuild}" -eq 0 ]]; then
    log_info "${name}: já instalado (skip). Use --rebuild para forçar."
    return 0
  fi

  _run_stage_hooks "pre-fetch" "${name}" "N/A"
  _fetch_sources_for "${name}"

  local bdir="${LFS_BUILDROOT}/${name}-${RANDOM}"
  _extract_to_builddir "${name}" "${bdir}"

  # Detecta subdiretório raiz (muitos tarballs criam uma pasta)
  local srcdir
  srcdir="$(find "${bdir}" -maxdepth 1 -mindepth 1 -type d | head -n1 || true)"
  [[ -n "${srcdir}" ]] || srcdir="${bdir}"

  _apply_patches "${name}" "${srcdir}"

  local dest="${LFS_STAGING}/${name}-${VERSION}"
  mkdir -p "${dest}"

  # Execução em chroot opcional
  if [[ "${use_chroot}" -eq 1 ]]; then
    require_cmd chroot
    # Copia fonte para /mnt/lfs/build e executa lá
    local ch_src="/build/$(basename -- "${srcdir}")"
    local ch_dest="/pkg/${name}-${VERSION}"
    rsync -a --delete "${srcdir}/" "/mnt/lfs${ch_src}/" 2>/dev/null || { mkdir -p "/mnt/lfs${ch_src}"; cp -a "${srcdir}/." "/mnt/lfs${ch_src}/"; }
    _run_stage_hooks "pre-build" "${name}" "${VERSION}"
    chroot "/mnt/lfs" /usr/bin/env -i /bin/bash -lc "cd '${ch_src}' && (type prepare &>/dev/null || true); true" || true
    # Stages
    chroot "/mnt/lfs" /usr/bin/env -i /bin/bash -lc "cd '${ch_src}' && export DESTDIR='${ch_dest}' JOBS='${jobs}' LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin:/tools/bin; if type prepare &>/dev/null; then prepare; fi"
    chroot "/mnt/lfs" /usr/bin/env -i /bin/bash -lc "cd '${ch_src}' && export DESTDIR='${ch_dest}' JOBS='${jobs}' LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin:/tools/bin; if type build &>/dev/null; then build; else ([[ -x ./configure ]] && ./configure --prefix=/usr || true); make -j'${jobs}'; fi"
    chroot "/mnt/lfs" /usr/bin/env -i /bin/bash -lc "cd '${ch_src}' && export DESTDIR='${ch_dest}' JOBS='${jobs}' LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin:/tools/bin; if type install &>/dev/null; then install; else make install; fi"
    _run_stage_hooks "post-build" "${name}" "${VERSION}"
    # Exporta artefato do chroot
    rsync -a "/mnt/lfs${ch_dest}/" "${dest}/"
  else
    _run_stage "${name}" prepare "${srcdir}" "${dest}" "${jobs}"
    _run_stage "${name}" build   "${srcdir}" "${dest}" "${jobs}"
    _run_stage "${name}" install "${srcdir}" "${dest}" "${jobs}"
  fi

  _write_meta "${name}" "${dest}"

  # Cria pacote .tar.zst automaticamente após build (produção)
  local pkg
  pkg="$(package_create "${NAME}" "${VERSION}" "${EPOCH}" "${RELEASE}" "${dest}")"
  log_info "Pacote gerado: ${pkg}"

  rm -rf "${bdir}"
  log_ok "Build OK: ${name}-${VERSION}"
}
#-----------------------------
# Build com resolução de dependências
#-----------------------------
build_with_deps() {
  local target="$1" jobs="$2" rebuild="$3" use_chroot="$4" force="$5"
  builder_bootstrap
  # Resolve ordem topológica
  local order
  order="$(printf '%s\n' "${target}" | _resolve_graph)"
  log_info "Ordem de build: $(echo "${order}" | tr '\n' ' ')"
  local p
  while IFS= read -r p; do
    if ! recipe_path "${p}" >/dev/null 2>&1; then
      die 1 "Receita ausente: ${p}"
    fi
    if is_installed "${p}" && [[ "${force}" -eq 0 && "${rebuild}" -eq 0 ]]; then
      log_info "${p}: já instalado (skip)"
      continue
    fi
    with_flock "build-${p}" 7200 build_one "${p}" "${jobs}" "${rebuild}" "${use_chroot}"
  done <<< "${order}"
}

#-----------------------------
# Utilidades públicas (export)
#-----------------------------
export -f build_one build_with_deps deps_graph deps_tree
