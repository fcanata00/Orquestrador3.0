pkgname="shadow-config"
pkgver="1.0"
pkgrel="1"
pkgdesc="Configuração inicial para shadow (login.defs, adduser helpers, nsswitch.conf)"
section="base"
license="BSD-2-Clause"
url="https://example.local/shadow-config"

source=()
sha256sums=()

builddir="${pkgname}-${pkgver}"
srcdir="${PWD}"

prepare(){ :; }
configure(){ :; }
build(){ :; }
check(){ :; }

install() {
  set -e
  mkdir -pv "${DESTDIR}/etc"
  # login.defs mínimo seguro
  cat > "${DESTDIR}/etc/login.defs" <<'EOF'
MAIL_DIR        /var/mail
PASS_MAX_DAYS   99999
PASS_MIN_DAYS   0
PASS_WARN_AGE   7
UID_MIN         1000
GID_MIN         1000
UMASK           022
ENCRYPT_METHOD  SHA512
SHA_CRYPT_MIN_ROUNDS 5000
SHA_CRYPT_MAX_ROUNDS 5000
EOF

  # nsswitch.conf básico
  cat > "${DESTDIR}/etc/nsswitch.conf" <<'EOF'
passwd: files
group:  files
shadow: files
hosts:  files dns
networks: files
protocols: files
services: files
ethers: files
rpc:     files
EOF

  # skeleton para /etc/skel
  mkdir -pv "${DESTDIR}/etc/skel"
  cat > "${DESTDIR}/etc/skel/.bash_profile" <<'EOF'
# ~/.bash_profile
[[ -f ~/.bashrc ]] && . ~/.bashrc
EOF
}

post_install(){ :; }

options=(tar.zst hooks fakeroot)
lockdeps=true
allow_cycles=false
fingerprint_env=true
fingerprint_abi=false
fingerprint_toolchain=false
