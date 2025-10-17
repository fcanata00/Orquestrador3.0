#!/usr/bin/env bash
# packager.sh — Empacotamento tar.zst, strip, manifests, install/upgrade/uninstall
# Depende: common.sh, recipes.sh (para nome/versão), builder.sh (metadados), chroot opcional

set -euo pipefail

: "${LFS_RUNTIME:=/usr/local/lib/lfs}"
# shellcheck source=/usr/local/lib/lfs/common.sh
. "${LFS_RUNTIME}/common.sh"
# shellcheck source=/usr/local/lib/lfs/recipes.sh
. "${LFS_RUNTIME}/recipes.sh"

# Diretórios de banco de dados de pacotes
: "${LFS_PKG_DIR:=/var/lib/lfs/packages}"            # onde ficam .tar.zst
: "${LFS_MANIFESTS_DIR:=/var/lib/lfs/manifests}"     # manifests por pacote
: "${LFS_INSTALLED_DIR:=/var/lib/lfs/db/installed}"  # metadados de instalação (já usado)
: "${LFS_STAGING:=/mnt/lfs/pkg}"                     # DESTDIR padrão do build
: "${LFS_ROOT_INSTALL:=/mnt/lfs}"                    # raiz de instalação final (bootstrap)

packager_bootstrap() {
  bootstrap_runtime
  mkdir -p "${LFS_PKG_DIR}" "${LFS_MANIFESTS_DIR}" "${LFS_INSTALLED_DIR}"
}

#-----------------------------
# Utils: versão & comparação
#-----------------------------
# Normaliza EPOCH:VER-REL em 3 campos
parse_evr() {
  local evr="$1" epoch ver rel
  epoch="${evr%%:*}"
  [[ "${epoch}" == "${evr}" ]] && epoch=0 || evr="${evr#*:}"
  ver="${evr%-*}"
  rel="${evr##*-}"
  echo "${epoch} ${ver} ${rel}"
}

# Compara evr1 > evr2 ? retorna 1 se evr1 é mais novo, 0 se igual, -1 se mais antigo
cmp_evr() {
  local a=($(parse_evr "$1")) b=($(parse_evr "$2"))
  # epoch numérico
  if (( ${a[0]} > ${b[0]} )); then echo 1; return; elif (( ${a[0]} < ${b[0]} )); then echo -1; return; fi
  # versão (lexicográfica com split por . e -)
  IFS='.-_' read -r -a va <<<"${a[1]}"; IFS='.-_' read -r -a vb <<<"${b[1]}"
  local n=$(( ${#va[@]} > ${#vb[@]} ? ${#va[@]} : ${#vb[@]} ))
  for ((i=0;i<n;i++)); do
    local xa="${va[i]:-0}" xb="${vb[i]:-0}"
    if [[ "$xa" =~ ^[0-9]+$ && "$xb" =~ ^[0-9]+$ ]]; then
      (( xa=10#$xa, xb=10#$xb ))
      if (( xa > xb )); then echo 1; return; elif (( xa < xb )); then echo -1; return; fi
    else
      if [[ "$xa" > "$xb" ]]; then echo 1; return; elif [[ "$xa" < "$xb" ]]; then echo -1; return; fi
    fi
  done
  # release numérico/lexi
  if [[ "${a[2]}" =~ ^[0-9]+$ && "${b[2]}" =~ ^[0-9]+$ ]]; then
    (( a2=10#${a[2]}, b2=10#${b[2]} ))
    if (( a2 > b2 )); then echo 1; return; elif (( a2 < b2 )); then echo -1; return; fi
  else
    if [[ "${a[2]}" > "${b[2]}" ]]; then echo 1; return; elif [[ "${a[2]}" < "${b[2]}" ]]; then echo -1; return; fi
  fi
  echo 0
}

#-----------------------------
# Strip em arquivos ELF
#-----------------------------
_is_elf() { file -L "$1" 2>/dev/null | grep -q 'ELF'; }

_do_strip() {
  local root="$1"
  command -v eu-strip >/dev/null 2>&1 && local STRIP_CMD="eu-strip" || local STRIP_CMD="strip"
  # bins e libs comuns
  local paths=( "${root}/usr/bin" "${root}/bin" "${root}/usr/sbin" "${root}/sbin" "${root}/usr/lib" "${root}/lib" "${root}/lib64" "${root}/usr/lib64" )
  for p in "${paths[@]}"; do
    [[ -d "${p}" ]] || continue
    while IFS= read -r -d '' f; do
      if _is_elf "${f}"; then
        # não quebra se falhar (símbolos ausentes etc)
        "${STRIP_CMD}" -g "${f}" 2>/dev/null || true
      fi
    done < <(find "${p}" -type f -print0)
  done
}

#-----------------------------
# Manifesto de arquivos
#-----------------------------
_manifest_write() {
  local name="$1" evr="$2" root="$3" manifest="${LFS_MANIFESTS_DIR}/${name}-${evr}.manifest"
  rm -f "${manifest}.tmp"
  # Formato: <mode> <uid> <gid> <type> <size> <sha256> <path>
  (
    cd "${root}"
    # arquivos regulares
    find . -xdev -type f -print0 | while IFS= read -r -d '' f; do
      local p="${f#./}"
      local st sha mode uid gid size
      read -r mode uid gid size < <(stat -Lc "%a %u %g %s" -- "$p")
      sha="$(sha256sum -- "$p" | awk '{print $1}')"
      echo "${mode} ${uid} ${gid} f ${size} ${sha} /${p}"
    done
    # diretórios
    find . -xdev -type d -print0 | while IFS= read -r -d '' d; do
      local p="${d#./}"
      read -r mode uid gid < <(stat -Lc "%a %u %g" -- "$p")
      echo "${mode} ${uid} ${gid} d 0 - /${p}"
    done
    # symlinks
    find . -xdev -type l -print0 | while IFS= read -r -d '' l; do
      local p="${l#./}"
      read -r mode uid gid < <(stat -Lc "%a %u %g" -- "$p")
      # para links, sha e size não se aplicam
      echo "${mode} ${uid} ${gid} l 0 - /${p}"
    done
  ) > "${manifest}.tmp"
  mv -f "${manifest}.tmp" "${manifest}"
  echo "${manifest}"
}

#-----------------------------
# Criação do pacote .tar.zst
#-----------------------------
package_create() {
  packager_bootstrap
  local name="$1" version="$2" epoch="${3:-0}" release="${4:-1}" staged="${5:-}"
  [[ -d "${staged}" ]] || die 2 "DESTDIR inexistente: ${staged}"

  local evr="${epoch}:${version}-${release}"
  local work="${staged%/}"        # root para leitura
  log_info "Strip de símbolos (ELF) em ${name}-${version}"
  _do_strip "${work}"

  log_info "Gerando manifesto..."
  local manifest; manifest="$(_manifest_write "${name}" "${evr}" "${work}")"

  local pkg="${LFS_PKG_DIR}/${name}-${version}-${release}.tar.zst"
  log_info "Empacotando ${pkg}"
  (
    cd "${work}"
    # preserva numeric owner, perms, links; compressão paralela zstd
    tar --posix --xattrs --acls --no-same-owner --numeric-owner -cf - . \
      | zstd -T0 -19 -o "${pkg}.tmp"
  )
  mv -f "${pkg}.tmp" "${pkg}"

  # metadados do pacote
  local meta="${LFS_INSTALLED_DIR}/${name}.meta"
  {
    echo "name=${name}"
    echo "version=${version}"
    echo "epoch=${epoch}"
    echo "release=${release}"
    echo "evr=${evr}"
    echo "package=${pkg}"
    echo "manifest=${manifest}"
    echo "build_time=$(date -u +%s)"
  } > "${meta}.pkg"
  log_ok "Pacote criado: ${pkg}"
  echo "${pkg}"
}

#-----------------------------
# Instalação do pacote no ROOT alvo
#-----------------------------
_install_files() {
  local root="$1" tarball="$2"
  mkdir -p "${root}"
  # extrai sobre o root sem alterar dono numérico (vamos assumir root:root no bootstrap)
  zstd -d -c "${tarball}" | tar -C "${root}" --numeric-owner --same-permissions --keep-directory-symlink -xf -
}

# Trata arquivos de config (em /etc): se existir e sha diferente, salva novo como .pacnew
_handle_configs_after_install() {
  local root="$1" manifest="$2"
  while read -r mode uid gid type size sha path; do
    [[ "${type}" != "f" ]] && continue
    [[ "${path}" != /etc/* ]] && continue
    local abs="${root}${path}"
    # se arquivo já existia antes e o conteúdo mudou, cria .pacnew
    if [[ -f "${abs}.new" ]]; then
      # quando tar sobrepõe, não cria .new; então vamos checar conflito: se existia antes e sha difere do manifesto
      :
    fi
  done < "${manifest}"
  # Implementação leve: comportamento padrão tar já sobrescreve;
  # Para modo conservador, poderíamos comparar backups anteriores. Mantemos simples aqui.
}

#-----------------------------
# Registra instalação e arquivo-lock reverso
#-----------------------------
_register_install() {
  local name="$1" evr="$2" root="$3" pkg="$4" manifest="$5"
  local meta="${LFS_INSTALLED_DIR}/${name}.meta"
  {
    echo "name=${name}"
    echo "evr=${evr}"
    echo "root=${root}"
    echo "package=${pkg}"
    echo "manifest=${manifest}"
    echo "install_time=$(date -u +%s)"
  } > "${meta}.tmp"
  mv -f "${meta}.tmp" "${meta}"
}

# Verifica dependentes reversos (simples via metadados de deps em builder/meta se houver)
reverse_deps() {
  local target="$1"
  local f
  for f in "${LFS_INSTALLED_DIR}"/*.meta; do
    [[ -f "$f" ]] || continue
    if grep -qE "^deps=.*\b${target}\b" "$f"; then
      echo "$(basename "$f" .meta)"
    fi
  done
}

package_install() {
  packager_bootstrap
  local tarball="$1" root="${2:-${LFS_ROOT_INSTALL}}"
  [[ -f "${tarball}" ]] || die 2 "Pacote não encontrado: ${tarball}"

  # extrai nome/versão do filename: name-ver-rel.tar.zst
  local base; base="$(basename -- "${tarball}")"
  local name ver rel
  name="${base%%-*}"
  ver_rel="${base#${name}-}"
  ver="${ver_rel%-*.tar.zst}"
  rel="${base##*-}"; rel="${rel%.tar.zst}"
  local epoch=0 evr="${epoch}:${ver}-${rel}"

  # instala
  log_info "Instalando ${name}-${ver}-${rel} em ${root}"
  with_flock "install-${name}" 3600 _install_files "${root}" "${tarball}"

  # registra
  local mani_guess="${LFS_MANIFESTS_DIR}/${name}-${epoch}:${ver}-${rel}.manifest"
  [[ -f "${mani_guess}" ]] || mani_guess=""
  _register_install "${name}" "${epoch}:${ver}-${rel}" "${root}" "${tarball}" "${mani_guess}"
  log_ok "Instalação concluída: ${name}-${ver}-${rel}"
}

#-----------------------------
# Uninstall com hooks
#-----------------------------
_remove_from_manifest() {
  local root="$1" manifest="$2"
  # Hooks de uninstall (globais)
  local hk_pre="${LFS_ETC}/hooks/pre-uninstall.d"
  local hk_post="${LFS_ETC}/hooks/post-uninstall.d"

  if [[ -d "${hk_pre}" ]]; then
    for f in "${hk_pre}/"*; do [[ -x "$f" ]] && "$f" "$manifest" "$root" || true; done
  fi

  # remove arquivos (somente os que ainda batem com o manifest / não confundir configs alteradas)
  while read -r mode uid gid type size sha path; do
    local abs="${root}${path}"
    case "${type}" in
      f)
        if [[ -f "${abs}" ]]; then
          local cursha; cursha="$(sha256sum -- "${abs}" 2>/dev/null | awk '{print $1}')" || cursha=""
          if [[ "${cursha}" == "${sha}" ]]; then
            rm -f -- "${abs}"
          else
            # arquivo modificado (provavelmente config) — preserva como .save
            mv -f -- "${abs}" "${abs}.save" 2>/dev/null || true
          fi
        fi
        ;;
      l) [[ -L "${abs}" ]] && rm -f -- "${abs}" || true ;;
      d) # remove diretórios vazios ao final
         ;;
    esac
  done < "${manifest}"

  # limpa diretórios vazios em ordem decrescente de profundidade
  awk '{print $7}' "${manifest}" | grep -E '^/.*' | awk -F/ '{print NF ":" $0}' | sort -rn | cut -d: -f2 \
    | while read -r p; do
        [[ -d "${root}${p}" ]] && rmdir --ignore-fail-on-non-empty "${root}${p}" 2>/dev/null || true
      done

  if [[ -d "${hk_post}" ]]; then
    for f in "${hk_post}/"*; do [[ -x "$f" ]] && "$f" "$manifest" "$root" || true; done
  fi
}

package_uninstall() {
  packager_bootstrap
  local name="$1" root="${2:-${LFS_ROOT_INSTALL}}" force="${3:-0}"
  local meta="${LFS_INSTALLED_DIR}/${name}.meta"
  [[ -f "${meta}" ]] || die 2 "Pacote não instalado: ${name}"

  if [[ "${force}" -ne 1 ]]; then
    local rev; rev="$(reverse_deps "${name}" || true)"
    if [[ -n "${rev}" ]]; then
      die 2 "Não é seguro remover '${name}': dependentes -> ${rev}"
    fi
  fi

  local manifest pkg evr
  manifest="$(awk -F= '$1=="manifest"{print $2}' "${meta}")"
  evr="$(awk -F= '$1=="evr"{print $2}' "${meta}")"
  pkg="$(awk -F= '$1=="package"{print $2}' "${meta}")"
  [[ -n "${manifest}" && -f "${manifest}" ]] || die 2 "Manifesto ausente para ${name}"

  log_info "Removendo ${name}-${evr} de ${root}"
  with_flock "uninstall-${name}" 3600 _remove_from_manifest "${root}" "${manifest}"
  rm -f -- "${meta}"
  log_ok "Removido: ${name}"
}

#-----------------------------
# Upgrade inteligente
#-----------------------------
package_upgrade() {
  packager_bootstrap
  local tarball="$1" root="${2:-${LFS_ROOT_INSTALL}}" force="${3:-0}"
  [[ -f "${tarball}" ]] || die 2 "Pacote não encontrado: ${tarball}"

  local base; base="$(basename -- "${tarball}")"
  local name ver rel epoch=0
  name="${base%%-*}"
  ver_rel="${base#${name}-}"
  ver="${ver_rel%-*.tar.zst}"
  rel="${base##*-}"; rel="${rel%.tar.zst}"
  local new_evr="${epoch}:${ver}-${rel}"

  local meta="${LFS_INSTALLED_DIR}/${name}.meta"
  if [[ -f "${meta}" ]]; then
    local cur_evr; cur_evr="$(awk -F= '$1=="evr"{print $2}' "${meta}")"
    local cmp; cmp="$(cmp_evr "${new_evr}" "${cur_evr}")"
    if [[ "${cmp}" -lt 0 && "${force}" -ne 1 ]]; then
      die 2 "Downgrade detectado (${new_evr} < ${cur_evr}). Use --force para permitir."
    fi
    # Uninstall preservando configs modificadas (já vira .save)
    package_uninstall "${name}" "${root}" 1
  fi

  package_install "${tarball}" "${root}"
  log_ok "Upgrade OK: ${name} -> ${new_evr}"
}

#-----------------------------
# Query/verify/list
#-----------------------------
package_info() {
  local name="$1"
  local meta="${LFS_INSTALLED_DIR}/${name}.meta"
  [[ -f "${meta}" ]] || die 2 "Pacote não instalado: ${name}"
  cat "${meta}"
}

package_files() {
  local name="$1"
  local meta="${LFS_INSTALLED_DIR}/${name}.meta"
  [[ -f "${meta}" ]] || die 2 "Pacote não instalado: ${name}"
  local manifest; manifest="$(awk -F= '$1=="manifest"{print $2}' "${meta}")"
  awk '{print $7}' "${manifest}"
}

package_verify() {
  local name="$1" root="${2:-${LFS_ROOT_INSTALL}}"
  local meta="${LFS_INSTALLED_DIR}/${name}.meta"
  [[ -f "${meta}" ]] || die 2 "Pacote não instalado: ${name}"
  local manifest; manifest="$(awk -F= '$1=="manifest"{print $2}' "${meta}")"
  local ok=0 bad=0
  while read -r mode uid gid type size sha path; do
    local abs="${root}${path}"
    case "${type}" in
      f)
        if [[ -f "${abs}" ]]; then
          local cursha; cursha="$(sha256sum -- "${abs}" | awk '{print $1}')" || cursha=""
          if [[ "${cursha}" == "${sha}" ]]; then ((ok++)); else ((bad++)); fi
        else ((bad++)); fi
        ;;
      l) [[ -L "${abs}" ]] && ((ok++)) || ((bad++)) ;;
      d) [[ -d "${abs}" ]] && ((ok++)) || ((bad++)) ;;
    esac
  done < "${manifest}"
  echo "verify: ok=${ok} bad=${bad}"
  [[ "${bad}" -eq 0 ]]
}

package_list_installed() {
  for f in "${LFS_INSTALLED_DIR}"/*.meta; do
    [[ -f "$f" ]] || continue
    awk -F= '
      BEGIN{n="";e="";p=""}
      $1=="name"{n=$2}
      $1=="evr"{e=$2}
      $1=="package"{p=$2}
      END{print n " " e " " p}
    ' "$f"
  done
}

package_gc() {
  # remove tarballs e manifests sem meta correspondente
  local removed=0
  for m in "${LFS_MANIFESTS_DIR}"/*.manifest; do
    [[ -f "$m" ]] || continue
    local base; base="$(basename -- "$m")"
    local name="${base%%-*}"
    if [[ ! -f "${LFS_INSTALLED_DIR}/${name}.meta" ]]; then
      rm -f -- "$m"
      ((removed++))
    fi
  done
  for t in "${LFS_PKG_DIR}"/*.tar.zst; do
    [[ -f "$t" ]] || continue
    local base; base="$(basename -- "$t")"
    local name="${base%%-*}"
    if [[ ! -f "${LFS_INSTALLED_DIR}/${name}.meta" ]]; then
      rm -f -- "$t"
      ((removed++))
    fi
  done
  log_ok "GC removidos: ${removed}"
}

export -f package_create package_install package_uninstall package_upgrade package_info package_files package_verify package_list_installed package_gc
