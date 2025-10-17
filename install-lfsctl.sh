#!/usr/bin/env bash
# --------------------------------------------------------------------
# install-lfsctl.sh — Instalador automático do LFSCTL (modular)
# Detecta repositório local e instala dentro de / ou /mnt/lfs
# --------------------------------------------------------------------
set -euo pipefail

# Cores para logs
GREEN="\e[1;32m"; YELLOW="\e[1;33m"; RED="\e[1;31m"; BLUE="\e[1;34m"; NC="\e[0m"

say() { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}==> AVISO:${NC} $*"; }
err() { echo -e "${RED}ERRO:${NC} $*" >&2; exit 1; }

# Detectar caminho base do repositório (raiz do Orquestrador)
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULES_DIR="${REPO_DIR}/orquestrador/modulos"
MANUAL_TXT="${REPO_DIR}/orquestrador/lfsctl-manual.txt"
BIN_LFSCTL="${MODULES_DIR}/lfsctl"

# Verificações básicas
[[ -d "$MODULES_DIR" ]] || err "Diretório de módulos não encontrado: $MODULES_DIR"
[[ -f "$BIN_LFSCTL" ]] || err "Binário lfsctl não encontrado em $BIN_LFSCTL"

# Perguntar destino da instalação
echo -e "${BLUE}Para onde deseja instalar o LFSCTL?${NC}"
echo "1) / (sistema host)"
echo "2) /mnt/lfs (sistema bootstrap/chroot)"
read -rp "Escolha [1-2]: " CHOICE

case "$CHOICE" in
  1) PREFIX="/" ;;
  2) PREFIX="/mnt/lfs" ;;
  *) err "Opção inválida." ;;
esac

say "Instalando no destino: ${PREFIX}"

# Diretórios de destino
LIBDIR="${PREFIX}/usr/local/lib/lfs"
BINDIR="${PREFIX}/usr/local/bin"
DOCDIR="${PREFIX}/usr/share/doc"
ETCDIR="${PREFIX}/etc/lfs"
VARDIR="${PREFIX}/var/lib/lfs"

# Criar estrutura de diretórios
say "Criando estrutura de diretórios..."
sudo mkdir -pv \
  "$LIBDIR" \
  "$BINDIR" \
  "$ETCDIR/recipes" \
  "$ETCDIR/hooks" \
  "$VARDIR"/{packages,cache,db,manifests,delta,rollback,history} \
  "$DOCDIR"

# Copiar módulos
say "Copiando módulos..."
sudo cp -v "$MODULES_DIR"/*.sh "$LIBDIR/"

# Copiar binário principal
say "Instalando binário lfsctl..."
sudo cp -v "$BIN_LFSCTL" "$BINDIR/lfsctl"

# Copiar manual
if [[ -f "$MANUAL_TXT" ]]; then
  say "Instalando manual..."
  sudo cp -v "$MANUAL_TXT" "$DOCDIR/lfsctl-manual.txt"
else
  warn "Manual lfsctl-manual.txt não encontrado — pulando."
fi

# Aplicar permissões
say "Ajustando permissões..."
sudo chmod 0755 "$BINDIR/lfsctl"
sudo chmod 0644 "$LIBDIR"/*.sh || true
sudo chmod -R 0755 "$ETCDIR" "$VARDIR" || true

# Proprietário
if [[ "$PREFIX" == "/mnt/lfs" ]]; then
  sudo chown -R $(whoami) "$PREFIX/usr" "$PREFIX/etc/lfs" "$PREFIX/var/lib/lfs"
else
  sudo chown -R root:root "$PREFIX/usr/local" || true
fi

say "Verificação final..."
ls -l "$LIBDIR" | grep '\.sh' || true
ls -l "$BINDIR/lfsctl" || true

say "Instalação concluída com sucesso!"
echo
echo -e "${GREEN}Para usar o LFSCTL:${NC}"
if [[ "$PREFIX" == "/mnt/lfs" ]]; then
  echo "  → Dentro do chroot:  /usr/local/bin/lfsctl"
  echo "  → Ou fora, use:      sudo chroot /mnt/lfs /usr/local/bin/lfsctl"
else
  echo "  → Execute normalmente:  lfsctl"
fi
echo
echo -e "${YELLOW}Manual:${NC} ${PREFIX}/usr/share/doc/lfsctl-manual.txt"
echo
