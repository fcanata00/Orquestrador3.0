# template-full.sh — Modelo completo de receita para o sistema LFSCTL
# ---------------------------------------------------------------
# Este template serve de referência e exemplo de todas as variáveis,
# funções, metadados e comportamentos suportados pelo sistema de build.
# ---------------------------------------------------------------

# 📦 Identificação básica do pacote
pkgname="exemplo"
pkgver="1.2.3"
pkgrel="4"                       # número de release (incrementa para rebuilds)
epoch="0"                        # prioridade de versão, raramente usado
pkgdesc="Exemplo de receita completa demonstrando todas as variáveis suportadas"
section="base"
url="https://www.exemplo.org/"
license="GPL-3.0-or-later"

# 🔗 Fontes (um ou vários) — URLs completas, suportando http(s), ftp, git
source=(
  "https://www.exemplo.org/releases/exemplo-${pkgver}.tar.xz"
  "https://mirror.exemplo.net/exemplo-${pkgver}.tar.xz"
)

# 🔐 Verificação de integridade — deve ter uma entrada por arquivo em source[]
sha256sums=(
  "deadbeef0123456789abcdef0123456789abcdef0123456789abcdef01234567"
  "deadbeef0123456789abcdef0123456789abcdef0123456789abcdef01234567"
)

# 🩹 Patches opcionais (aplicados em ordem)
patches=(
  "https://patches.exemplo.org/fix-paths.patch"
  "https://patches.exemplo.org/security-fix.patch"
)
patch_sha256sums=(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
)

# 🧬 Repositório Git alternativo (opcional)
# Se definido, ignora SOURCE e baixa via git clone.
git_repo="https://github.com/exemplo/exemplo.git"
git_ref="v${pkgver}"          # branch, tag ou commit hash
git_depth=1                   # shallow clone
git_submodules="true"         # habilita atualização de submódulos

# 🧩 Dependências
depends=(zlib openssl)        # dependências runtime
makedepends=(cmake ninja)     # dependências só para build
provides=(libexemplo.so)      # fornece estes símbolos/bibliotecas
conflicts=(exemplo-old)       # entra em conflito com outro pacote
replaces=(exemplo-beta)       # substitui versões antigas

# 💾 Diretórios e variáveis de ambiente padrão
builddir="exemplo-${pkgver}"  # diretório onde o código-fonte é expandido
srcdir="${PWD}"               # diretório raiz de extração (controlado pelo lfsctl)
DESTDIR="${DESTDIR:-$PWD/_pkg}"  # pasta temporária de instalação
JOBS="${JOBS:-$(nproc)}"      # paralelismo padrão

# 📁 Flags padrão (podem ser sobrescritas)
CFLAGS="${CFLAGS:--O2 -pipe -fPIC}"
CXXFLAGS="${CXXFLAGS:--O2 -pipe -fPIC}"
LDFLAGS="${LDFLAGS:--Wl,-O1,--as-needed}"
MAKEFLAGS="-j${JOBS}"

# 🔧 Configuração específica do ambiente LFS
LFS_TGT="${LFS_TGT:-x86_64-lfs-linux-gnu}"
LFS_ROOT="${LFS_ROOT:-/mnt/lfs}"
LFS_TOOLS="${LFS_TOOLS:-/mnt/lfs/tools}"

# 🧱 Fase opcional de pre_download
pre_download() {
    log_info "Preparando ambiente de download..."
    # Pode ser usado para criar pastas de cache customizadas
}

# 📥 Preparação — extração, aplicação de patches, ajustes de árvore
prepare() {
    log_info "Extraindo fontes..."
    tar -xf "$LFS_SRC_CACHE/${source[0]}" || die 1 "Falha ao extrair"
    cd "$builddir" || die 1 "Diretório de build não encontrado"

    log_info "Aplicando patches..."
    for p in "${patches[@]}"; do
        patch -Np1 -i "$LFS_PATCH_CACHE/$(basename "$p")" || die 1 "Erro no patch $p"
    done

    log_info "Rodando autoreconf se necessário..."
    if [[ -f configure.ac ]]; then autoreconf -fi || true; fi
}

# ⚙️ Configuração — ./configure, cmake, meson, etc.
configure() {
    log_info "Configurando pacote..."
    ./configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --disable-static \
        --enable-shared \
        --with-openssl \
        --with-zlib \
        CFLAGS="${CFLAGS}" \
        CXXFLAGS="${CXXFLAGS}" \
        LDFLAGS="${LDFLAGS}" || die 1 "Erro em configure"
}

# 🏗️ Compilação
build() {
    log_info "Compilando com ${JOBS} jobs..."
    make ${MAKEFLAGS} || die 1 "Erro no make"
}

# 🧪 Testes (opcional)
check() {
    log_info "Executando testes..."
    make -k check || log_warn "Testes falharam (ignorado em modo bootstrap)"
}

# 📦 Instalação (dentro de DESTDIR)
install() {
    log_info "Instalando em DESTDIR=${DESTDIR}..."
    make DESTDIR="${DESTDIR}" install || die 1 "Falha na instalação"
}

# 🧹 Pós-instalação — limpeza, links simbólicos, cache, hooks
post_install() {
    log_info "Rodando limpeza pós-instalação..."
    rm -f "${DESTDIR}/usr/share/doc/exemplo/README.old" || true
    ln -sf "exemplo-${pkgver}" "${DESTDIR}/usr/bin/exemplo-current"

    # Exemplo de hook customizado
    if declare -F hook_after_install >/dev/null; then
        hook_after_install "$pkgname" "$pkgver"
    fi
}

# 🧩 Hooks opcionais suportados pelo sistema:
# - pre_download()
# - prepare()
# - configure()
# - build()
# - check()
# - install()
# - post_install()
# - pre_uninstall()
# - post_uninstall()
# - pre_upgrade()
# - post_upgrade()

# 🧰 Opções avançadas e controle de build
options=(
  "strip"            # executa strip automático
  "tar.zst"          # empacota com zstd
  "fakeroot"         # instala em DESTDIR sob fakeroot
  "parallel"         # habilita paralelismo
  "error-silent"     # erros são logados, não abortam
  "hooks"            # executa hooks globais do sistema
)

# 🔒 Travas e controle de dependências
lockdeps=true        # impede builds simultâneos do mesmo pacote
allow_cycles=false   # bloqueia dependências cíclicas

# 🔁 Suporte a reconstrução inteligente
fingerprint_abi=true
fingerprint_env=true
fingerprint_toolchain=true

# 🧩 Exemplo de funções auxiliares opcionais específicas
pkg_ver_compare() {
    # Compara duas versões, retorna 0 se iguais, 1 se diferente
    [[ "$1" == "$2" ]]
}

pkg_custom_strip() {
    # Strip customizado (opcional)
    find "$DESTDIR" -type f -name "*.so*" -exec strip --strip-unneeded {} + 2>/dev/null || true
}

# 🧱 Fim da receita
