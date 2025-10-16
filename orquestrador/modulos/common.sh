#!/usr/bin/env bash
# common.sh — Núcleo compartilhado para a suíte LFS/BLFS
# Requisitos: bash >= 4, coreutils, util-linux (flock), grep, sed, awk

set -euo pipefail

#=============
# Constantes
#=============
: "${LFS_PREFIX:=/}"                                # pode ser / durante operação normal
: "${LFS_ETC:=/etc/lfs}"
: "${LFS_ETC_D:=${LFS_ETC}/config.d}"
: "${LFS_LOG_DIR:=/var/log/lfs}"
: "${LFS_VAR_LIB:=/var/lib/lfs}"
: "${LFS_CACHE:=/var/cache/lfs}"
: "${LFS_REPO:=/repo/local}"
: "${LFS_RUNTIME:=/usr/local/lib/lfs}"             # onde ficam libs
: "${LFS_LOCK_DIR:=${LFS_VAR_LIB}/locks}"
: "${LFS_STATE_DIR:=${LFS_VAR_LIB}/state}"
: "${LFS_DB_DIR:=${LFS_VAR_LIB}/db}"
: "${LFS_RECIPES_DIR:=${LFS_VAR_LIB}/recipes}"

: "${LFS_DEFAULT_CONFIG_FILE:=${LFS_ETC}/config}"

# Defaults ajustáveis via config/env:
: "${LFS_MAX_JOBS:=0}"          # 0 => auto (nproc)
: "${LFS_MAX_FETCH:=4}"
: "${LFS_COLOR:=auto}"          # auto|always|never
: "${LFS_VERBOSE:=1}"           # 0-3 (quiet..debug)
: "${LFS_LOG_TZ:=UTC}"          # TZ para timestamps

#===================
# Util: terminal/cores
#===================
_is_tty() { [[ -t 1 ]]; }

_color_enable() {
  case "${LFS_COLOR}" in
    always) return 0 ;;
    never)  return 1 ;;
    auto)   _is_tty ;;
    *)      _is_tty ;;
  esac
}

if _color_enable; then
  __c_reset=$'\033[0m'
  __c_dim=$'\033[2m'
  __c_bold=$'\033[1m'
  __c_red=$'\033[31m'
  __c_green=$'\033[32m'
  __c_yellow=$'\033[33m'
  __c_blue=$'\033[34m'
else
  __c_reset=""; __c_dim=""; __c_bold=""
  __c_red=""; __c_green=""; __c_yellow=""; __c_blue=""
fi

#===================
# Logs
#===================
mkdir -p "${LFS_LOG_DIR}"
: "${LFS_LOG_FILE:=${LFS_LOG_DIR}/lfsctl.log}"

_ts() { TZ="${LFS_LOG_TZ}" date +"%Y-%m-%dT%H:%M:%S%z"; }

_log() {
  local level="$1"; shift
  local color prefix
  case "$level" in
    INFO)  color="${__c_blue}";;
    OK)    color="${__c_green}";;
    WARN)  color="${__c_yellow}";;
    ERROR) color="${__c_red}";;
    DEBUG) color="${__c_dim}";;
    *)     color="";;
  esac
  prefix="[$(_ts)][$level]"
  if _color_enable; then
    echo -e "${color}${prefix}${__c_reset} $*" | tee -a "${LFS_LOG_FILE}" >&2
  else
    echo "${prefix} $*" | tee -a "${LFS_LOG_FILE}" >&2
  fi
}

log_info()  { [[ "${LFS_VERBOSE}" -ge 1 ]] && _log INFO  "$*"; }
log_ok()    { [[ "${LFS_VERBOSE}" -ge 1 ]] && _log OK    "$*"; }
log_warn()  { [[ "${LFS_VERBOSE}" -ge 0 ]] && _log WARN  "$*"; }
log_error() { _log ERROR "$*"; }
log_debug() { [[ "${LFS_VERBOSE}" -ge 3 ]] && _log DEBUG "$*"; }

#===================
# Stacktrace / traps
#===================
_stacktrace() {
  local i=0
  echo "Stacktrace:" >&2
  while caller $i >&2; do
    ((i++)) || true
  done
}

die() {
  local code="${1:-1}"; shift || true
  log_error "$*"
  _stacktrace
  exit "${code}"
}

trap 'code=$?; [[ $code -ne 0 ]] && log_error "Falha (exit=$code)"; exit $code' EXIT
trap 'die 130 "Interrompido (SIGINT)";' INT
trap 'die 143 "Interrompido (SIGTERM)";' TERM

#===================
# Checagens & requisitos
#===================
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die 127 "Comando obrigatório não encontrado: $c"
  done
}

detect_nproc() {
  if command -v nproc >/dev/null 2>&1; then nproc; else getconf _NPROCESSORS_ONLN || echo 1; fi
}

effective_jobs() {
  local j="${LFS_MAX_JOBS}"
  if [[ "${j}" -le 0 ]]; then j="$(detect_nproc)"; fi
  [[ "$j" -ge 1 ]] || j=1
  echo "$j"
}

assert_root() {
  [[ ${EUID} -eq 0 ]] || die 1 "Este comando requer root (EUID=${EUID})"
}

assert_not_root() {
  [[ ${EUID} -ne 0 ]] || die 1 "Por segurança, não rode como root"
}

#===================
# Config loader
#===================
# Aceita KEY=VALUE (sem espaços) e ignora linhas iniciadas por #.
load_config_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  log_debug "Carregando config: $f"
  # shellcheck disable=SC2162
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      eval "export ${line}"
    else
      log_warn "Linha inválida em $f: $line"
    fi
  done < "$f"
}

load_config() {
  mkdir -p "${LFS_ETC_D}"
  load_config_file "${LFS_DEFAULT_CONFIG_FILE}"
  local cf
  for cf in "${LFS_ETC_D}"/*.conf; do
    [[ -e "$cf" ]] || continue
    load_config_file "$cf"
  done
}

ensure_default_config() {
  mkdir -p "${LFS_ETC_D}"
  if [[ ! -f "${LFS_DEFAULT_CONFIG_FILE}" ]]; then
    cat > "${LFS_DEFAULT_CONFIG_FILE}" <<'CFG'
# /etc/lfs/config — configuração principal da suíte LFS
# Níveis de verbosidade: 0=quiet,1=info,2=verbose,3=debug
LFS_VERBOSE=1
# auto|always|never
LFS_COLOR=auto
# 0 => usar nproc
LFS_MAX_JOBS=0
LFS_MAX_FETCH=4
# Repositório local
LFS_REPO=/repo/local
# Diretórios padrões
LFS_CACHE=/var/cache/lfs
LFS_VAR_LIB=/var/lib/lfs
LFS_LOG_DIR=/var/log/lfs
# Timezone para timestamps de log
LFS_LOG_TZ=UTC
CFG
    chmod 0644 "${LFS_DEFAULT_CONFIG_FILE}"
  fi
}

#===================
# Diretórios padrão
#===================
ensure_dirs() {
  mkdir -p \
    "${LFS_LOG_DIR}" \
    "${LFS_CACHE}/"{sources,tarballs,git} \
    "${LFS_VAR_LIB}/"{locks,state,db,recipes} \
    "${LFS_REPO}/"{packages,index}
  chmod 0755 "${LFS_LOG_DIR}" "${LFS_CACHE}" "${LFS_VAR_LIB}" "${LFS_REPO}"
}

#===================
# Locks (flock)
#===================
with_flock() {
  local name="$1" timeout="${2:-300}"; shift 2 || true
  mkdir -p "${LFS_LOCK_DIR}"
  local lockfile="${LFS_LOCK_DIR}/${name}.lock"
  exec {lockfd}> "${lockfile}" || die 1 "Não foi possível abrir lock ${lockfile}"
  if ! flock -w "${timeout}" "${lockfd}"; then
    die 1 "Timeout ao aguardar lock ${name}"
  fi
  echo "$$ $(hostname -s) $(date +%s)" > "${lockfile}.owner"
  "$@"
  flock -u "${lockfd}" || true
  rm -f "${lockfile}.owner" || true
}

lock_status() {
  local name="$1"
  local lockfile="${LFS_LOCK_DIR}/${name}.lock"
  if [[ -f "${lockfile}" ]]; then
    echo "locked"
    [[ -f "${lockfile}.owner" ]] && cat "${lockfile}.owner"
  else
    echo "unlocked"
  fi
}

#===================
# Paralelismo genérico
#===================
# run_parallel <max> <cmd...>  — executa a mesma <cmd> para cada item lido da STDIN
# Uso: printf '%s\n' item1 item2 | run_parallel 4 myfunc
run_parallel() {
  local max="$1"; shift
  [[ -z "${1:-}" ]] && die 2 "run_parallel: falta comando"
  [[ "${max}" -lt 1 ]] && max=1

  if command -v xargs >/dev/null 2>&1; then
    # Cada linha vira um argumento para o comando
    xargs -r -P "${max}" -I{} bash -c '"$@" "$item"' _ "$@" item="{}"
  else
    # Fallback com jobs em background + semáforo simples
    local sem fifo
    fifo="$(mktemp -u)"
    mkfifo "${fifo}"
    exec 9<>"${fifo}"
    rm -f "${fifo}"
    for ((sem=0; sem<max; sem++)); do echo >&9; done
    while IFS= read -r item; do
      read -u 9
      {
        "$@" "$item" || exit $?
        echo >&9
      } &
    done
    wait
    exec 9>&-
  fi
}

#===================
# Utilidades diversas
#===================
rotate_log() {
  local f="${1:-${LFS_LOG_FILE}}"
  [[ -f "$f" ]] || return 0
  local ts; ts="$(date +%Y%m%d%H%M%S)"
  mv -f "$f" "${f}.${ts}.rotated"
}

tail_logs() {
  local n="${1:-200}"
  [[ -f "${LFS_LOG_FILE}" ]] || { echo "Sem log em ${LFS_LOG_FILE}"; return 0; }
  tail -n "${n}" "${LFS_LOG_FILE}"
}

print_env_summary() {
  echo "LFS_PREFIX=${LFS_PREFIX}"
  echo "LFS_ETC=${LFS_ETC}"
  echo "LFS_LOG_DIR=${LFS_LOG_DIR}"
  echo "LFS_CACHE=${LFS_CACHE}"
  echo "LFS_VAR_LIB=${LFS_VAR_LIB}"
  echo "LFS_REPO=${LFS_REPO}"
  echo "LFS_MAX_JOBS=$(effective_jobs)"
  echo "LFS_MAX_FETCH=${LFS_MAX_FETCH}"
  echo "LFS_COLOR=${LFS_COLOR}"
  echo "LFS_VERBOSE=${LFS_VERBOSE}"
}

doctor_checks() {
  local missing=()
  local req=(bash awk sed grep cut tr sort uniq tee date mkdir mv rm cp chmod cat
             flock tar zstd sha256sum curl wget git gpg fakeroot chroot mount umount)
  for c in "${req[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Faltando comandos: ${missing[*]}"
    return 1
  fi
  return 0
}

#===================
# Inicialização
#===================
bootstrap_runtime() {
  ensure_default_config
  load_config
  ensure_dirs
  : "${LFS_LOG_FILE:=${LFS_LOG_DIR}/lfsctl.log}"
}

# Fim common.sh
