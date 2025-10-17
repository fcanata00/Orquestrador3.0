# glibc.sh — Receita do GNU C Library (glibc) — para lfsctl
# Base: LFS development, capítulo 5.5 “Glibc-2.42” 1

pkgname="glibc"
pkgver="2.42"
pkgrel="1"
pkgdesc="GNU C Library — suporte fundamental de C / APIs do sistema"
section="base"
url="https://www.gnu.org/software/libc/"

# Fontes principais
source=(
  "https://ftp.gnu.org/gnu/libc/glibc-${pkgver}.tar.xz"
)
sha256sums=(
  "PLACEHOLDER_FOR_REAL_SHA256_HASH"
)

# Patches (ex: patch FHS para relocations) — opcional conforme LFS
patches=(
  "glibc-${pkgver}-fhs-1.patch"
)
patch_sha256sums=(
  "PLACEHOLDER_FOR_PATCH_HASH"
)

# Dependências mínimas
depends=(gcc-pass1 linux-api-headers)   # runtime deps
makedepends=()                          # deps para build

# Diretórios
builddir="glibc-${pkgver}"
srcdir="${PWD}"
# DESTDIR será fornecido pelo lfsctl / builder
# JOBS é herdado do lfsctl

# Flags padrão (podem ser modificadas)
CFLAGS="${CFLAGS:--O2 -pipe}"
CXXFLAGS="${CXXFLAGS:-}"
LDFLAGS="${LDFLAGS:--Wl,-O1,--as-needed}"
MAKEFLAGS="-j${JOBS}"

# ===========================
# Fases da receita
# ===========================

prepare() {
  cd "$srcdir"
  # Extrair tarball
  tar -xf "$(basename "${source[0]}")" || die 1 "Falha na extração do glibc"
  cd "$builddir"

  # Aplicar patches
  for p in "${patches[@]}"; do
    patch -Np1 -i "${srcdir}/${p}" || die 1 "Falha ao aplicar patch $p"
  done

  # Ajustes recomendados pelo LFS: criar pasta configparms com rootsbindir
  {
    echo "rootsbindir=/usr/sbin"
  } > configparms

  # Marcadores FHS: relocalizar /var/db para /var/lib, se necessário
  # (adaptar patch FHS)
}

configure() {
  cd "${srcdir}/${builddir}"
  mkdir -v build
  cd build

  ../configure \
    --prefix=/usr \
    --host="$LFS_TGT" \
    --build=$(../scripts/config.guess) \
    --disable-nscd \
    libc_cv_slibdir=/usr/lib \
    --enable-kernel=5.4 \
    --disable-werror \
    || die 1 "Configure falhou para glibc"
}

build() {
  cd "${srcdir}/${builddir}/build"
  make ${MAKEFLAGS} || die 1 "Falha ao compilar glibc"
}

check() {
  cd "${srcdir}/${builddir}/build"
  # executar testes (alguns podem falhar)
  make check || {
    log_warn "Alguns testes de glibc falharam — verificar relatório"
  }
}

install() {
  cd "${srcdir}/${builddir}/build"
  make DESTDIR="${DESTDIR}" install || die 1 "Falha no make install"
}

post_install() {
  # Criar links simbólicos para loaders compatíveis e compatibilidade FHS
  local lfsroot="${DESTDIR}"
  case "$(uname -m)" in
    x86_64)
      ln -sv ../lib/ld-linux-x86-64.so.2 "${lfsroot}/lib64"
      ln -sv ../lib/ld-linux-x86-64.so.2 "${lfsroot}/lib64/ld-lsb-x86-64.so.3"
      ;;
    i?86)
      ln -sv ld-linux.so.2 "${lfsroot}/lib/ld-lsb.so.3"
      ;;
  esac

  # Garantir /etc/ld.so.conf existe (evita warning)
  mkdir -pv "${lfsroot}/etc"
  touch "${lfsroot}/etc/ld.so.conf"
}

# ===========================
# Opções da receita (meta)
# ===========================

options=(strip tar.zst parallel hooks)  # suporte a strip, compressão, paralelismo, hooks

lockdeps=true
allow_cycles=false

fingerprint_abi=true
fingerprint_env=true
fingerprint_toolchain=true
