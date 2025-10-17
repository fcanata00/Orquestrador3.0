# binutils-pass1.sh — Receita para Binutils Pass 1 no lfsctl
# Base no capítulo “Binutils-Pass1” de LFS Stable / LFS 12 (ex: versão 2.x) 0

pkgname="binutils-pass1"
pkgver="2.44"
pkgrel="1"
pkgdesc="GNU Binutils — Passo 1 do toolchain (linker, assembler) para bootstrap"
section="toolchain"
license="GPL-3.0-or-later"
url="https://www.gnu.org/software/binutils/"

# Fontes
source=(
  "https://ftp.gnu.org/gnu/binutils/binutils-${pkgver}.tar.xz"
)
sha256sums=(
  "PUT_REAL_SHA256_HASH_FOR_binutils_tarball"
)

# Patches opcionais (exemplo: patch para compilar com gcc recentes)
patches=()
patch_sha256sums=()

# Dependências (runtime / build) mínimas
depends=()
makedepends=()

# Diretórios
builddir="binutils-${pkgver}"
srcdir="${PWD}"

# Flags padrão
JOBS="${JOBS:-$(nproc)}"
MAKEFLAGS="-j${JOBS}"
CFLAGS="${CFLAGS:--O2 -pipe}"
CXXFLAGS="${CXXFLAGS:-}"
LDFLAGS="${LDFLAGS:--Wl,-O1,--as-needed}"

# ------------------------------------------------
prepare() {
  set -e
  cd "$srcdir"
  tar -xf "$(basename "${source[0]}")"
  cd "${builddir}"
  # (nenhum patch padrão no LFS stable para pass1)
}

configure() {
  cd "${srcdir}/${builddir}"
  mkdir -v build
  cd build

  ../configure \
    --prefix="$LFS_TOOLS" \
    --with-sysroot="$LFS" \
    --target="$LFS_TGT" \
    --disable-nls \
    --disable-werror \
    --enable-shared \
    --enable-64-bit-bfd \
    --disable-multilib \
    || die 1 "configure falhou para binutils-pass1"
}

build() {
  cd "${srcdir}/${builddir}/build"
  make ${MAKEFLAGS} || die 1 "Falha no build de binutils-pass1"
}

check() {
  # No LFS, a fase pass1 normalmente não roda testes completos por dependências faltantes
  :
}

install() {
  cd "${srcdir}/${builddir}/build"
  make DESTDIR="${DESTDIR}" install || die 1 "Falha no install de binutils-pass1"
  # Ajuste do linker para preparação: limpar e reconstrói ld
  make -C ld clean
  make -C ld LIB_PATH="$LFS_TOOLS/lib" || die 1 "Falha no rebuild de ld com LIB_PATH"
}

post_install() {
  # Nenhum passo extra geralmente necessário aqui no pass1
  :
}

options=(strip tar.zst parallel hooks fakeroot)
lockdeps=true
allow_cycles=false

fingerprint_abi=false    # binutils pass1 ABI não crítico
fingerprint_env=true
fingerprint_toolchain=true
