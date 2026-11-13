#!/usr/bin/env bash
# Soluciona: Unable to lookup session information for process 'XXXX'
# Causa: ConsoleKit esta activo pero la sesion esta registrada en systemd-logind.
# Solucion: quitar ConsoleKit y asegurar que logind gestione la sesion.
#
# Uso: sudo bash fix-consolekit2.sh

set -u

if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

. /etc/os-release
DISTRO="${ID:-unknown} ${ID_LIKE:-}"

echo ">> Deteniendo ConsoleKit..."
systemctl disable --now console-kit-daemon 2>/dev/null || true
pkill -f console-kit-daemon 2>/dev/null || true

echo ">> Desinstalando ConsoleKit y su integracion PAM..."
case "$DISTRO" in
    *debian*|*ubuntu*|*mint*)
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -y consolekit libpam-ck-connector 2>/dev/null || true
        apt-get install -y libpam-systemd systemd
        apt-get autoremove -y
        ;;
    *arch*|*manjaro*)
        pacman -Rns --noconfirm consolekit 2>/dev/null || true
        ;;
    *fedora*|*rhel*|*centos*)
        dnf remove -y ConsoleKit ConsoleKit-libs 2>/dev/null || true
        ;;
    *suse*)
        zypper --non-interactive remove ConsoleKit 2>/dev/null || true
        ;;
esac

echo ">> Asegurando systemd-logind..."
systemctl unmask systemd-logind 2>/dev/null || true
systemctl enable --now systemd-logind 2>/dev/null || true

echo ">> Verificacion:"
loginctl list-sessions 2>/dev/null || echo "loginctl no disponible"
echo
if [ -z "${SUDO_USER:-}" ]; then SUDO_USER="$(logname 2>/dev/null || echo "")"; fi
if [ -n "$SUDO_USER" ]; then
    echo "Sesion de $SUDO_USER:"
    loginctl show-user "$SUDO_USER" -p Sessions -p State 2>/dev/null || true
fi

echo
echo ">> Listo. CIERRA SESION y vuelve a entrar (o reinicia) para que la sesion se registre en logind."
