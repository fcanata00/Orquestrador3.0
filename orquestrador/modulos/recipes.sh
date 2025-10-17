#!/usr/bin/env bash
# recipes.sh — Descoberta, carga e lint de receitas LFS/BLFS
# Depende: common.sh

set -euo pipefail

: "${LFS_RUNTIME:=/usr/local/lib/lfs}"
# shellcheck source=/usr/local/lib/lfs/common.sh
. "${LFS_RUNTIME}/common.sh"

# Diretórios-padrão de receitas:
# - /var/lib/lfs/recipes (writable para admin)
# - /usr/local/share/lfs/recipes (somente leitura, upstream)
: "${LFS_RECIPES_DIR:=/var/lib/lfs/recipes}"
: "${LFS_RECIPES_SYS:=/usr/local/share/lfs/recipes}"

recipes_bootstrap() {
  bootstrap_runtime
  mkdir -p "${LFS_RECIPES_DIR}"
}

# Localiza caminho da receita por nome (ex: "zlib")
# Busca primeiro em LFS_RECIPES_DIR, depois em LFS_RECIPES_SYS.
recipe_path() {
  local name="$1"
  local p1="${LFS_RECIPES_DIR}/${name}.sh"
  local p2="${LFS_RECIPES_DIR}/${name}/${name}.sh"
  local s1="${LFS_RECIPES_SYS}/${name}.sh"
  local s2="${LFS_RECIPES_SYS}/${name}/${name}.sh"
  if [[ -f "${p1}" ]]; then echo "${p1}"; return 0; fi
  if [[ -f "${p2}" ]]; then echo "${p2}"; return 0; fi
  if [[ -f "${s1}" ]]; then echo "${s1}"; return 0; fi
  if [[ -f "${s2}" ]]; then echo "${s2}"; return 0; fi
  return 1
}

# Carrega uma receita num subshell e imprime variáveis essenciais no formato KEY=VAL
# Saída segura para avaliação via "eval".
_recipe_dump_env() {
  local file="$1"
  (
    set -euo pipefail
    # Isola variáveis e impede side-effects
    unset NAME VERSION EPOCH RELEASE SUMMARY HOMEPAGE LICENSE
    unset -f prepare build install || true
    # shellcheck disable=SC1090
    . "${file}"
    : "${NAME?}"; : "${VERSION?}"
    : "${EPOCH:=0}"; : "${RELEASE:=1}"
    : "${SUMMARY:=}"; : "${HOMEPAGE:=}"; : "${LICENSE:=}"
    : "${CHROOT:=0}"   # 1 => preferir build em chroot

    # Arrays podem não existir
    declare -p DEPS     >/dev/null 2>&1 || declare -a DEPS=()
    declare -p BUILD_DEPS >/dev/null 2>&1 || declare -a BUILD_DEPS=()
    declare -p SOURCE   >/dev/null 2>&1 || declare -a SOURCE=()
    declare -p SHA256   >/dev/null 2>&1 || declare -a SHA256=()
    declare -p PATCHES  >/dev/null 2>&1 || declare -a PATCHES=()
    declare -p PATCHES_SHA256 >/dev/null 2>&1 || declare -a PATCHES_SHA256=()
    : "${GIT_URL:=}"; : "${GIT_REF:=}"

    # Emite variáveis no formato que o chamador pode "eval"
    echo "NAME=$(printf %q "${NAME}")"
    echo "VERSION=$(printf %q "${VERSION}")"
    echo "EPOCH=$(printf %q "${EPOCH}")"
    echo "RELEASE=$(printf %q "${RELEASE}")"
    echo "SUMMARY=$(printf %q "${SUMMARY}")"
    echo "HOMEPAGE=$(printf %q "${HOMEPAGE}")"
    echo "LICENSE=$(printf %q "${LICENSE}")"
    echo "CHROOT=$(printf %q "${CHROOT}")"
    echo "GIT_URL=$(printf %q "${GIT_URL}")"
    echo "GIT_REF=$(printf %q "${GIT_REF}")"
    # Serializa arrays em linhas separadas
    printf 'DEPS=';        declare -p DEPS        | sed -E 's/^declare -a DEPS=//'
    printf 'BUILD_DEPS=';  declare -p BUILD_DEPS  | sed -E 's/^declare -a BUILD_DEPS=//'
    printf 'SOURCE=';      declare -p SOURCE      | sed -E 's/^declare -a SOURCE=//'
    printf 'SHA256=';      declare -p SHA256      | sed -E 's/^declare -a SHA256=//'
    printf 'PATCHES=';     declare -p PATCHES     | sed -E 's/^declare -a PATCHES=//'
    printf 'PATCHES_SHA256='; declare -p PATCHES_SHA256 | sed -E 's/^declare -a PATCHES_SHA256=//'
    # Indica quais funções existem
    declare -F prepare >/dev/null 2>&1 && echo "HAS_PREPARE=1" || echo "HAS_PREPARE=0"
    declare -F build   >/dev/null 2>&1 && echo "HAS_BUILD=1"   || echo "HAS_BUILD=0"
    declare -F install >/dev/null 2>&1 && echo "HAS_INSTALL=1" || echo "HAS_INSTALL=0"
  )
}

# Lê receita e popula variáveis no caller (usa eval com saída controlada)
recipe_load() {
  local name="$1" file
  file="$(recipe_path "${name}")" || die 2 "Receita não encontrada: ${name}"
  eval "$(_recipe_dump_env "${file}")"
  export NAME VERSION EPOCH RELEASE SUMMARY HOMEPAGE LICENSE CHROOT
  export GIT_URL GIT_REF
}

# Lint básico da receita (campos obrigatórios e cardinalidade)
recipe_lint() {
  local name="$1"
  recipe_load "${name}"
  [[ -n "${NAME}" && -n "${VERSION}" ]] || die 1 "NAME/VER ausentes"
  if [[ ${#SOURCE[@]:-0} -gt 0 ]]; then
    [[ ${#SOURCE[@]} -eq ${#SHA256[@]} ]] || die 1 "SOURCE e SHA256 com tamanhos diferentes"
  fi
  if [[ ${#PATCHES[@]:-0} -gt 0 ]]; then
    [[ ${#PATCHES[@]} -eq ${#PATCHES_SHA256[@]} ]] || die 1 "PATCHES e PATCHES_SHA256 com tamanhos diferentes"
  fi
  if [[ -n "${GIT_URL}" && -z "${GIT_REF}" ]]; then
    die 1 "GIT_URL exige GIT_REF definido"
  fi
  log_ok "Lint OK: ${name}-${VERSION}"
}

# Imprime receita "normalizada" para inspeção
recipe_print() {
  local name="$1" file
  file="$(recipe_path "${name}")" || die 2 "Receita não encontrada: ${name}"
  recipe_load "${name}"
  cat <<OUT
# FILE: ${file}
NAME=${NAME}
VERSION=${VERSION}
EPOCH=${EPOCH}
RELEASE=${RELEASE}
SUMMARY=${SUMMARY}
HOMEPAGE=${HOMEPAGE}
LICENSE=${LICENSE}
CHROOT=${CHROOT}
DEPS=(${DEPS[*]:-})
BUILD_DEPS=(${BUILD_DEPS[*]:-})
SOURCE=(${SOURCE[*]:-})
SHA256=(${SHA256[*]:-})
PATCHES=(${PATCHES[*]:-})
PATCHES_SHA256=(${PATCHES_SHA256[*]:-})
GIT_URL=${GIT_URL}
GIT_REF=${GIT_REF}
OUT
}

# Lista dependências (run + build)
recipe_deps_all() {
  recipe_load "$1"
  printf '%s\n' "${DEPS[@]:-}" "${BUILD_DEPS[@]:-}" | grep -vE '^\s*$' || true
}

# Topo: apenas runtime
recipe_deps_runtime() {
  recipe_load "$1"
  printf '%s\n' "${DEPS[@]:-}" | grep -vE '^\s*$' || true
}
