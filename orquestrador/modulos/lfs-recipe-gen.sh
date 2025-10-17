#!/usr/bin/env bash
# lfs-recipe-gen.sh — Gerador automático de receita lfsctl a partir de páginas do livro LFS
# Uso:
#   ./lfs-recipe-gen.sh --name gcc-pass1 --version 15.2.0 --url https://www.linuxfromscratch.org/lfs/view/stable/chapter05/gcc-pass1.html > /etc/lfs/recipes/gcc-pass1.sh
#   ./lfs-recipe-gen.sh --name glibc --version 2.42 --file ./glibc.html > /etc/lfs/recipes/glibc.sh
#
# Estratégia:
#  - Extrai blocos de comandos de <pre>...</pre> do HTML
#  - Normaliza comandos e distribui heurísticamente entre fases:
#      prepare: tar/patch/sed/autoreconf/mkdir build/cd
#      configure: ./configure | cmake | meson
#      build: make (sem install/check)
#      check: make check / test
#      install: make install
#      post_install: links, ajustes finais
#
# Limitações: algumas páginas variam; revise a saída e ajuste a mão quando necessário.

set -euo pipefail

NAME=""
VERSION=""
SOURCE_URLS=()     # opcional: --src URL ... (pode repetir)
INPUT=""           # --url https://... OU --file caminho.html
PKGREL="1"
SECTION="base"
DESC="Pacote gerado a partir do livro LFS"
LICENSE="GPL-2.0-or-later"
WITH_PATCHES=()    # opcional: --patch URL ... (pode repetir)

die(){ echo "Erro: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    --url) INPUT="$2"; shift 2;;
    --file) INPUT="$2"; shift 2;;
    --src) SOURCE_URLS+=("$2"); shift 2;;
    --patch) WITH_PATCHES+=("$2"); shift 2;;
    --desc) DESC="$2"; shift 2;;
    --section) SECTION="$2"; shift 2;;
    --license) LICENSE="$2"; shift 2;;
    --rel|--pkgrel) PKGREL="$2"; shift 2;;
    *) die "opção desconhecida: $1";;
  esac
done

[[ -n "$NAME" && -n "$VERSION" && -n "$INPUT" ]] || die "Uso: --name N --version V --url URL|--file ARQ [--src URL ...] [--patch URL ...]"

fetch_html() {
  if [[ "$INPUT" =~ ^https?:// ]]; then
    command -v curl >/dev/null 2>&1 || die "curl não encontrado"
    curl -fsSL "$INPUT"
  else
    [[ -f "$INPUT" ]] || die "arquivo não encontrado: $INPUT"
    cat "$INPUT"
  fi
}

# Extrai blocos <pre>...</pre> preservando quebras
extract_pre_blocks() {
  # Simplista porém efetivo: coleta tudo entre <pre...> e </pre>
  awk '
    BEGIN{IGNORECASE=1}
    /<pre/ {inpre=1; buf=""; next}
    /<\/pre>/ {inpre=0; print buf; buf=""; next}
    { if(inpre){ buf = buf $0 "\n" } }
  '
}

# Remove tags html residuais e entities comuns
cleanup_code() {
  sed 's/\r//g' \
  | sed -e 's/&gt;/>/g; s/&lt;/</g; s/&amp;/\&/g; s/<[^>]*>//g'
}

# Heurística de roteamento por fase
route_lines() {
  awk '
    function push(arr, s) { arr[++n[arr]]=s }
    BEGIN{
      nprep=0; nconf=0; nbld=0; nchk=0; ninst=0; npost=0;
    }
    {
      line=$0
      # ignora linhas vazias ou comentários HTML removidos
      if (line ~ /^[[:space:]]*$/) next

      low=line
      gsub(/\t/,"  ",low)
      # prepare heuristics
      if (low ~ /^(tar|xz|unxz|bunzip2|bzip2|gunzip|unzip|patch|sed|autoreconf|cp|mv|ln|rm|install|mkdir|cd )/ ||
          low ~ /mkdir -p/ || low ~ /^cat .* > .*$/) {
        prep[++nprep]=line; next
      }
      # configure heuristics
      if (low ~ /^(\.\/configure|cmake |meson )/ ||
          low ~ /configure --/ ) {
        conf[++nconf]=line; next
      }
      # build heuristics
      if (low ~ /^make( |$)/ && low !~ /install/ && low !~ /check/ ) {
        bld[++nbld]=line; next
      }
      # check heuristics
      if (low ~ /^make .*check/ || low ~ /ctest/ || low ~ /meson test/) {
        chk[++nchk]=line; next
      }
      # install heuristics
      if (low ~ /^make .*install/ || low ~ /^install /) {
        inst[++ninst]=line; next
      }
      # post_install default
      post[++npost]=line; next
    }
    END{
      print "===PREPARE==="; for(i=1;i<=nprep;i++) print prep[i];
      print "===CONFIGURE==="; for(i=1;i<=nconf;i++) print conf[i];
      print "===BUILD==="; for(i=1;i<=nbld;i++) print bld[i];
      print "===CHECK==="; for(i=1;i<=nchk;i++) print chk[i];
      print "===INSTALL==="; for(i=1;i<=ninst;i++) print inst[i];
      print "===POST==="; for(i=1;i<=npost;i++) print post[i];
    }
  '
}

HTML="$(fetch_html)"
RAW_BLOCKS="$(printf "%s" "$HTML" | extract_pre_blocks | cleanup_code)"
ROUTED="$(printf "%s" "$RAW_BLOCKS" | route_lines)"

emit_array() {
  local tag="$1"; shift
  local -a arr=( "$@" )
  echo "${tag}=("
  for u in "${arr[@]}"; do
    printf '  "%s"\n' "$u"
  done
  echo ")"
}

# Gera a receita completa
cat <<'HDR'
# ATENÇÃO: receita gerada automaticamente por lfs-recipe-gen.sh
HDR

cat <<EOF
pkgname="${NAME}"
pkgver="${VERSION}"
pkgrel="${PKGREL}"
pkgdesc="${DESC}"
section="${SECTION}"
license="${LICENSE}"
url="$(dirname "${INPUT}")"

EOF

emit_array "source" "${SOURCE_URLS[@]:-}"
echo
# placeholders para sha256
if ((${#SOURCE_URLS[@]})); then
  echo "sha256sums=("
  for _ in "${SOURCE_URLS[@]}"; do
    echo '  "PUT_REAL_SHA256_HERE"'
  done
  echo ")"
  echo
fi

if ((${#WITH_PATCHES[@]})); then
  emit_array "patches" "${WITH_PATCHES[@]}"
  echo "patch_sha256sums=("
  for _ in "${WITH_PATCHES[@]}"; do
    echo '  "PUT_PATCH_SHA256_HERE"'
  done
  echo ")"
  echo
fi

cat <<'VARS'
# Diretórios padrão
builddir="${builddir:-${pkgname}-${pkgver}}"
srcdir="${srcdir:-$PWD}"
JOBS="${JOBS:-$(nproc)}"
MAKEFLAGS="-j${JOBS}"

# Flags usuais
CFLAGS="${CFLAGS:--O2 -pipe -fPIC}"
CXXFLAGS="${CXXFLAGS:--O2 -pipe -fPIC}"
LDFLAGS="${LDFLAGS:--Wl,-O1,--as-needed}"

VARS

prep_block="$(printf "%s" "$ROUTED" | awk '/^===PREPARE===/{f=1;next}/^===/{f=0}f{print}')"
conf_block="$(printf "%s" "$ROUTED" | awk '/^===CONFIGURE===/{f=1;next}/^===/{f=0}f{print}')"
bld_block="$(printf "%s" "$ROUTED" | awk '/^===BUILD===/{f=1;next}/^===/{f=0}f{print}')"
chk_block="$(printf "%s" "$ROUTED" | awk '/^===CHECK===/{f=1;next}/^===/{f=0}f{print}')"
inst_block="$(printf "%s" "$ROUTED" | awk '/^===INSTALL===/{f=1;next}/^===/{f=0}f{print}')"
post_block="$(printf "%s" "$ROUTED" | awk '/^===POST===/{f=1;next}/^===/{f=0}f{print}')"

# Emite funções com proteção e diretivas mínimas
emit_func(){
  local name="$1" content="$2"
  echo "${name}() {"
  echo "  set -e"
  echo "  cd \"\$srcdir\""
  echo "  # Extração padrão se o tarball estiver no cache (ajuste se necessário)"
  echo "  # tar -xf \"\$LFS_SRC_CACHE/\${source[0]##*/}\""
  echo "  # cd \"\$builddir\""
  echo
  if [[ -n "$content" ]]; then
    # identa e preserva
    printf "%s\n" "$content" | sed 's/^/  /'
  else
    echo "  :"
  fi
  echo "}"
  echo
}

emit_func "prepare" "$prep_block"
emit_func "configure" "$conf_block"
emit_func "build" "$bld_block"
emit_func "check" "$chk_block"
emit_func "install" "$inst_block"
emit_func "post_install" "$post_block"

cat <<'TAIL'
options=(strip tar.zst parallel hooks fakeroot)

lockdeps=true
allow_cycles=false

fingerprint_abi=true
fingerprint_env=true
fingerprint_toolchain=true
TAIL
