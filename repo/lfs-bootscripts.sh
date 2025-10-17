pkgname="lfs-bootscripts"
pkgver="20240701"
pkgrel="1"
pkgdesc="Scripts de inicialização padrão do LFS (System V ou systemd units auxiliares, conforme bundle)"
section="base"
license="GPL-2.0-or-later"
url="https://www.linuxfromscratch.org/lfs/"

source=(
  "https://www.linuxfromscratch.org/lfs/downloads/${pkgver}/lfs-bootscripts-${pkgver}.tar.xz"
)
sha256sums=(
  "PUT_REAL_SHA256_HERE"
)

builddir="lfs-bootscripts-${pkgver}"
srcdir="${PWD}"
JOBS="${JOBS:-$(nproc)}"

prepare() {
  set -e
  cd "$srcdir"
  tar -xf "$LFS_SRC_CACHE/lfs-bootscripts-${pkgver}.tar.xz"
}

configure() { :; }

build() { :; }

check() { :; }

install() {
  set -e
  cd "$srcdir/$builddir"
  make DESTDIR="${DESTDIR}" install
  # Garante diretórios básicos que os scripts assumem:
  mkdir -pv "${DESTDIR}/etc/{rc.d,sysconfig,sysconfig/network-scripts}" || true
}

post_install() {
  set -e
  # Nada extra aqui por padrão — hooks podem preencher configs.
}

options=(strip tar.zst parallel hooks fakeroot)
lockdeps=true
allow_cycles=false
fingerprint_abi=false
fingerprint_env=true
fingerprint_toolchain=false
