pkgname="bashrc-lfs"
pkgver="1.0"
pkgrel="1"
pkgdesc="Bashrc e profile padrão para ambiente LFS (host/chroot/bootstrap)"
section="base"
license="MIT"
url="https://example.local/bashrc-lfs"

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
  mkdir -pv "${DESTDIR}/etc/profile.d"
  cat > "${DESTDIR}/etc/profile.d/lfs.sh" <<'EOF'
# /etc/profile.d/lfs.sh — PATH e prompt amigável
case ":$PATH:" in
  *:/tools/bin:*) ;;
  *) [ -d /tools/bin ] && export PATH=/tools/bin:/bin:/usr/bin:/sbin:/usr/sbin ;;
esac
export PS1='\u@\h:\w\$ '
EOF
  chmod 0644 "${DESTDIR}/etc/profile.d/lfs.sh"

  # Bashrc global
  cat > "${DESTDIR}/etc/bash.bashrc" <<'EOF'
# /etc/bash.bashrc — ajustes gerais
shopt -s histappend checkwinsize
export HISTSIZE=2000
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
EOF

  # Skeleton para usuários novos
  mkdir -pv "${DESTDIR}/etc/skel"
  cat > "${DESTDIR}/etc/skel/.bashrc" <<'EOF'
# ~/.bashrc padrão LFS
[[ $- != *i* ]] && return
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
PS1='\u@\h:\w\$ '
EOF
}

post_install(){ :; }

options=(tar.zst hooks fakeroot)
lockdeps=true
allow_cycles=false
fingerprint_env=true
fingerprint_abi=false
fingerprint_toolchain=false
