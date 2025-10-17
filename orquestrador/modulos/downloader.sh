#!/usr/bin/env bash
# downloader.sh — Biblioteca de download/cache/verificação LFS
# Depende de: common.sh

set -euo pipefail

: "${LFS_RUNTIME:=/usr/local/lib/lfs}"
# shellcheck source=/usr/local/lib/lfs/common.sh
. "${LFS_RUNTIME}/common.sh"

#========================
# Config e defaults
#========================
: "${LFS_KEYS_DIR:=${LFS_ETC}/keys}"      # keyring GPG
: "${LFS_MIRRORS:=}"                      # ex: "https://mirror1.example https://mirror2.example"
: "${LFS_FETCH_RETRIES:=4}"
: "${LFS_FETCH_BACKOFF:=2}"               # segundos base, exponencial
: "${LFS_USER_AGENT:=lfsctl/1.0 (+https://local)}"

dl_bootstrap() {
  bootstrap_runtime
  mkdir -p "${LFS_KEYS_DIR}"
  require_cmd sha256sum tar zstd
  # fetchers
  if command -v curl >/dev/null 2>&1; then
    : "${DL_TOOL:=curl}"
  elif command -v wget >/dev/null 2>&1; then
    : "${DL_TOOL:=wget}"
  else
    die 127 "Requer curl ou wget para downloads."
  fi
}

#========================
# Baixa uma URL para um arquivo destino (com resume e retries)
# dl_fetch_url <url> <outfile>
#========================
dl_fetch_url() {
  local url="$1" out="$2"
  local tries="${LFS_FETCH_RETRIES}"
  local i=1 delay="${LFS_FETCH_BACKOFF}"

  mkdir -p "$(dirname -- "$out")"
  local tmp="${out}.part"

  while (( i <= tries )); do
    log_info "Baixando (${i}/${tries}): ${url}"
    if [[ "${DL_TOOL}" == "curl" ]]; then
      if curl -fL --retry 0 -A "${LFS_USER_AGENT}" -C - -o "${tmp}" "${url}"; then
        mv -f "${tmp}" "${out}"
        log_ok "OK: ${out}"
        return 0
      fi
    else
      if wget -O "${tmp}" -c --user-agent="${LFS_USER_AGENT}" "${url}"; then
        mv -f "${tmp}" "${out}"
        log_ok "OK: ${out}"
        return 0
      fi
    fi
    log_warn "Falha ao baixar: ${url} (tentativa ${i})"
    rm -f "${tmp}" || true
    (( i++ ))
    sleep "$(( delay ))"
    delay="$(( delay * 2 ))"
  done

  die 1 "Exaustão de tentativas para: ${url}"
}

#========================
# Expande mirrors para uma URL base.
# Se LFS_MIRRORS está definido, tenta <mirror>/<basename(url)>.
#========================
dl_build_mirror_urls() {
  local url="$1"
  local basefile; basefile="$(basename -- "$url")"
  local alt=()
  for m in ${LFS_MIRRORS:-}; do
    alt+=( "${m%/}/${basefile}" )
  done
  printf '%s\n' "${alt[@]}" 2>/dev/null || true
}

#========================
# Tenta URL original e mirrors
# dl_fetch_with_mirrors <url> <outfile>
#========================
dl_fetch_with_mirrors() {
  local url="$1" out="$2"
  if dl_fetch_url "${url}" "${out}"; then
    return 0
  fi
  log_warn "Tentando mirrors para ${url}"
  local m
  while read -r m; do
    [[ -z "$m" ]] && continue
    if dl_fetch_url "${m}" "${out}"; then
      log_ok "Baixado via espelho: ${m}"
      return 0
    fi
  done < <(dl_build_mirror_urls "${url}")
  die 1 "Falha em URL e mirrors: ${url}"
}

#========================
# Verificação SHA256
# dl_verify_sha256 <file> <expected_hex>
#========================
dl_verify_sha256() {
  local file="$1" expected="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
  local got
  got="$(sha256sum -b -- "${file}" | awk '{print $1}')"
  if [[ "${got}" != "${expected}" ]]; then
    die 1 "SHA256 inválido para ${file}: obtido=${got} esperado=${expected}"
  fi
  log_ok "SHA256 OK: ${file}"
}

#========================
# Verificação GPG (opcional)
# dl_verify_gpg <file> <sigfile> [keyring_dir]
#========================
dl_verify_gpg() {
  local file="$1" sig="$2" kdir="${3:-${LFS_KEYS_DIR}}"
  require_cmd gpg
  [[ -f "${sig}" ]] || die 1 "Assinatura inexistente: ${sig}"
  GNUPGHOME="$(mktemp -d)"
  export GNUPGHOME
  chmod 0700 "${GNUPGHOME}"
  if compgen -G "${kdir}/*" >/dev/null; then
    # Importa todas as chaves do diretório
    gpg --import "${kdir}/"* >/dev/null 2>&1 || true
  else
    log_warn "Keyring vazio em ${kdir}; verificação pode falhar."
  fi
  if gpg --verify "${sig}" "${file}" >/dev/null 2>&1; then
    log_ok "GPG OK: ${file}"
  else
    rm -rf "${GNUPGHOME}"
    die 1 "Falha na verificação GPG de ${file} contra ${sig}"
  fi
  rm -rf "${GNUPGHOME}"
}

#========================
# Fetch de um item unitário
# dl_fetch_one <name> <url> <sha256> [sig_url_or_path] [outdir]
#========================
dl_fetch_one() {
  local name="$1" url="$2" hash="$3"
  local sig="${4:-}" outdir="${5:-${LFS_CACHE}/sources}"
  mkdir -p "${outdir}"

  local fname="${name:-$(basename -- "$url")}"
  [[ "$fname" == *.* ]] || fname="$(basename -- "$url")" # fallback se o nome não tiver extensão
  local out="${outdir}/${fname}"

  if [[ -f "${out}" ]]; then
    log_info "Cache hit: ${out}"
    dl_verify_sha256 "${out}" "${hash}"
  else
    dl_fetch_with_mirrors "${url}" "${out}"
    dl_verify_sha256 "${out}" "${hash}"
  fi

  if [[ -n "${sig}" ]]; then
    local sigfile
    if [[ "${sig}" =~ ^https?:// ]]; then
      sigfile="${out}.asc"
      dl_fetch_with_mirrors "${sig}" "${sigfile}"
    else
      sigfile="${sig}"
    fi
    dl_verify_gpg "${out}" "${sigfile}" "${LFS_KEYS_DIR}"
  fi

  echo "${out}"
}

#========================
# Lista em arquivo para batch:
# Formato por linha (pipes) — linhas iniciadas com # são ignoradas
# name|url|sha256|[sigurl_or_path]
# Exemplos:
#  zlib-1.3.1|https://zlib.net/zlib-1.3.1.tar.xz|<sha256>|https://zlib.net/zlib-1.3.1.tar.xz.asc
#  pkgconf-2.3.0|https://dist/pkgconf-2.3.0.tar.xz|<sha256>|
#========================
dl_fetch_list() {
  local listfile="$1" outdir="${2:-${LFS_CACHE}/sources}" parallel="${3:-$(effective_jobs)}"
  [[ -f "${listfile}" ]] || die 2 "Lista não encontrada: ${listfile}"
  local _worker
  _worker() {
    local line="$1"
    IFS='|' read -r name url hash sig <<<"$line"
    [[ -z "${name}" || -z "${url}" || -z "${hash}" ]] && { log_warn "Linha inválida: ${line}"; return 0; }
    dl_fetch_one "${name}" "${url}" "${hash}" "${sig:-}" "${outdir}" >/dev/null
  }
  # Alimenta somente linhas úteis
  grep -vE '^\s*#' "${listfile}" | grep -vE '^\s*$' | run_parallel "${parallel}" _worker
  log_ok "Lista processada: ${listfile}"
}

#========================
# Git → tar.zst reprodutível
# dl_git_archive --url URL --ref REF --name NAME [--outdir DIR]
# Saída: <outdir>/<name>-<shortref>.git.tar.zst
#========================
dl_git_archive() {
  local url="" ref="" name="" outdir="${LFS_CACHE}/tarballs"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url) url="$2"; shift 2 ;;
      --ref) ref="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --outdir) outdir="$2"; shift 2 ;;
      *) die 2 "Parâmetro inválido para dl_git_archive: $1" ;;
    esac
  done
  [[ -n "${url}" && -n "${ref}" && -n "${name}" ]] || die 2 "Uso: dl_git_archive --url URL --ref REF --name NAME [--outdir DIR]"

  mkdir -p "${outdir}" "${LFS_CACHE}/git"
  require_cmd git

  local workdir; workdir="$(mktemp -d "${LFS_CACHE}/git/${name}.XXXX")"
  trap 'rm -rf "${workdir}" || true' RETURN

  log_info "Clonando git (shallow) ${url} @ ${ref}"
  git -c advice.detachedHead=false clone --no-tags --filter=blob:none --depth 1 "${url}" "${workdir}" >/dev/null 2>&1 || {
    # fallback: init + fetch ref
    git -C "${workdir}" init >/dev/null
    git -C "${workdir}" remote add origin "${url}" >/dev/null
    git -C "${workdir}" fetch --no-tags --depth 1 origin "${ref}" >/dev/null
    git -C "${workdir}" checkout FETCH_HEAD >/dev/null
  }

  # Garante o ref correto
  if ! git -C "${workdir}" rev-parse --verify -q "${ref}^{commit}" >/dev/null 2>&1; then
    # pode ser branch/tag já checado
    :
  else
    git -C "${workdir}" checkout -q "${ref}"
  fi

  local commit; commit="$(git -C "${workdir}" rev-parse --verify HEAD)"
  local shortref; shortref="$(git -C "${workdir}" rev-parse --short=12 HEAD)"
  local epoch; epoch="$(git -C "${workdir}" show -s --format=%ct HEAD)"
  export SOURCE_DATE_EPOCH="${epoch}"

  local tarname="${name}-${shortref}.git.tar"
  local out="${outdir}/${tarname}.zst"

  log_info "Empacotando árvore git reprodutível: ${out}"
  (cd "${workdir}" && \
    TZ=UTC LC_ALL=C LANG=C \
    git archive --format=tar --prefix="${name}/" "${commit}" > "${workdir}/${tarname}")

  zstd -T"$(effective_jobs)" -19 -f "${workdir}/${tarname}" -o "${out}" >/dev/null
  log_ok "Gerado: ${out}"
  echo "${out}"
}
