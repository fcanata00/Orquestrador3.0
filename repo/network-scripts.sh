pkgname="network-scripts"
pkgver="1.0"
pkgrel="1"
pkgdesc="Configuração de rede básica para LFS (ifup/ifdown e sysconfig)"
section="base"
license="BSD-3-Clause"
url="https://example.local/network-scripts"

# Sem tarball: gerado do próprio recipe (inline)
source=()
sha256sums=()

builddir="${pkgname}-${pkgver}"
srcdir="${PWD}"

prepare() { :; }
configure() { :; }
build() { :; }
check() { :; }

install() {
  set -e
  # Diretórios de configuração
  mkdir -pv "${DESTDIR}/etc/sysconfig/network-scripts"
  mkdir -pv "${DESTDIR}/etc/sysconfig"

  # Arquivos de configuração modelo
  cat > "${DESTDIR}/etc/sysconfig/ifconfig.eth0" <<'EOF'
ONBOOT=yes
IFACE=eth0
SERVICE=ipv4-static
IP=192.168.1.100
GATEWAY=192.168.1.1
PREFIX=24
BROADCAST=192.168.1.255
EOF

  cat > "${DESTDIR}/etc/sysconfig/network" <<'EOF'
HOSTNAME=lfs
DNS1=1.1.1.1
DNS2=8.8.8.8
EOF

  # Scripts simples de ifup/ifdown
  mkdir -pv "${DESTDIR}/sbin"
  cat > "${DESTDIR}/sbin/ifup" <<'EOF'
#!/bin/sh
set -eu
IF="${1:-eth0}"
. /etc/sysconfig/ifconfig.$IF
ip link set "$IF" up
if [ "${SERVICE}" = "ipv4-static" ]; then
  ip addr add "${IP}/${PREFIX}" dev "$IF"
  ip route add default via "${GATEWAY}"
fi
exit 0
EOF
  chmod 0755 "${DESTDIR}/sbin/ifup"

  cat > "${DESTDIR}/sbin/ifdown" <<'EOF'
#!/bin/sh
set -eu
IF="${1:-eth0}"
ip addr flush dev "$IF" || true
ip link set "$IF" down || true
exit 0
EOF
  chmod 0755 "${DESTDIR}/sbin/ifdown"

  # resolv.conf modelo
  mkdir -pv "${DESTDIR}/etc"
  cat > "${DESTDIR}/etc/resolv.conf" <<'EOF'
# gerenciado pelo network-scripts (modelo)
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
}

post_install() { :; }

options=(tar.zst hooks fakeroot)
lockdeps=true
allow_cycles=false
fingerprint_env=true
fingerprint_abi=false
fingerprint_toolchain=false
