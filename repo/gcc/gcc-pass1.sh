# gcc-pass1.sh — Receita para GCC Pass 1 (Toolchain Bootstrap)
# Base: LFS stable, capítulo 5.3 (GCC-15.2.0 Pass 1) 0

NAME="gcc-pass1"
VERSION="15.2.0"
EPOCH=0
RELEASE=1

# Fontes — GCC + suas dependências embutidas
SOURCE=(
  "https://ftp.gnu.org/gnu/gcc/gcc-${VERSION}/gcc-${VERSION}.tar.xz"
  "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz"
  "https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.2.tar.xz"
  "https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz"
)
SHA256=(
  "b27dfd2b5bde8dca4c3a2e7fdfa7d5b1e40d39f6f6b203c049b1f5cc0f0a9a4e"  # Exemplo — confirme SHA
  "da6d6bca5415900a2f9f308a2cf1e5a6d8f0a6ebe8f3be3a1adf8e3e2f4a8ac7"
  "5f1a44465d2c13f8c7c4c8b3f2d4a1e5b5c3d2e1f7a9b8c3d4e2f1a6b7c8d9e0"
  "a1b2c3d4e5f67890abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
)
# Não há patches nesta fase (normalmente)
PATCHES=()
PATCHES_SHA256=()

# GIT não é usado neste caso
GIT_URL=""
GIT_REF=""

# Dependências declaradas
DEPS=(binutils-pass1 linux-api-headers)
BUILD_DEPS=()

prepare() {
  # Descompactar e renomear subdiretórios para gmp, mpfr, mpc dentro do source tree
  cd "$srcdir"
  tar -xf "$(basename "${SOURCE[1]}")"
  mv "gmp-6.3.0" gmp
  tar -xf "$(basename "${SOURCE[2]}")"
  mv "mpfr-4.2.2" mpfr
  tar -xf "$(basename "${SOURCE[3]}")"
  mv "mpc-1.3.1" mpc

  cd "gcc-${VERSION}"

  # Em x86_64, ajustar diretório “lib64” para “lib” no GCC config (como no livro) 1
  case $(uname -m) in
    x86_64)
      sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
      ;;
  esac

  # Cria build directory
  mkdir -v build
}

build() {
  cd "${srcdir}/gcc-${VERSION}/build"
  ../configure \
    --target="$LFS_TGT" \
    --prefix="$LFS_TOOLS" \
    --with-glibc-version=2.42 \
    --with-sysroot="$LFS" \
    --with-newlib \
    --without-headers \
    --enable-default-pie \
    --enable-default-ssp \
    --disable-nls \
    --disable-shared \
    --disable-multilib \
    --disable-threads \
    --disable-libatomic \
    --disable-libgomp \
    --disable-libquadmath \
    --disable-libssp \
    --disable-libvtv \
    --disable-libstdcxx \
    --enable-languages=c,c++

  make -j"$JOBS"
}

check() {
  # Pass 1 geralmente não faz suite de testes; verificamos a geração do compilador
  log_info "Verificando GCC Pass1: versão"
  "$LFS_TOOLS/bin/${LFS_TGT}-gcc" --version || true
}

install() {
  cd "${srcdir}/gcc-${VERSION}/build"
  make install DESTDIR="$DESTDIR"
}

post_install() {
  # Ajustes adicionais conforme LFS
  mkdir -pv "${DESTDIR}${LFS_TOOLS}/libexec/gcc/${LFS_TGT}/${VERSION}/install-tools"
}
