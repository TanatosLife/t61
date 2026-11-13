#!/usr/bin/env bash
# Soluciona: GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown:
#            The name org.freedesktop.ConsoleKit was not provided by any .service files
#
# Causa: una aplicacion (gestor de archivos, menu de apagado, lxsession, etc.)
# intenta hablar con ConsoleKit por D-Bus, pero ese servicio no esta instalado
# o no esta activo. Los sistemas modernos usan systemd-logind en su lugar.
#
# Uso: sudo bash fix-consolekit.sh

set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "Reejecutando con sudo..."
    exec sudo bash "$0" "$@"
fi

. /etc/os-release
DISTRO="${ID:-unknown} ${ID_LIKE:-}"
echo ">> Distribucion detectada: $DISTRO"

install_pkgs() {
    case "$DISTRO" in
        *debian*|*ubuntu*|*mint*)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y dbus dbus-x11 libpam-systemd systemd
            # polkit: el nombre cambia segun la version
            apt-get install -y polkitd pkexec 2>/dev/null || apt-get install -y policykit-1
            # ConsoleKit solo si el paquete aun existe en tu version
            apt-get install -y consolekit 2>/dev/null || echo "(consolekit no disponible, se usara systemd-logind)"
            ;;
        *arch*|*manjaro*)
            pacman -Sy --needed --noconfirm dbus polkit systemd
            ;;
        *fedora*|*rhel*|*centos*)
            dnf install -y dbus polkit systemd
            ;;
        *suse*)
            zypper --non-interactive install dbus-1 polkit systemd
            ;;
        *)
            echo "Distribucion no reconocida. Instala manualmente: dbus, polkit, systemd (o consolekit)."
            ;;
    esac
}

install_pkgs

echo ">> Activando servicios..."
if [ -d /run/systemd/system ]; then
    systemctl enable --now dbus 2>/dev/null || true
    systemctl unmask systemd-logind 2>/dev/null || true
    systemctl enable --now systemd-logind 2>/dev/null || true
    systemctl enable --now polkit 2>/dev/null || true
    # Si se instalo consolekit, activarlo tambien
    if systemctl list-unit-files 2>/dev/null | grep -q '^console-kit-daemon'; then
        systemctl enable --now console-kit-daemon 2>/dev/null || true
    fi
else
    echo "Systemd no esta en uso (WSL, contenedor o init alternativo)."
    # Sistemas sin systemd: iniciar dbus y ConsoleKit a mano
    service dbus start 2>/dev/null || /etc/init.d/dbus start 2>/dev/null || true
    if command -v console-kit-daemon >/dev/null 2>&1; then
        console-kit-daemon 2>/dev/null || true
    fi
fi

echo ">> Verificacion:"
if gdbus introspect --system --dest org.freedesktop.login1 --object-path /org/freedesktop/login1 >/dev/null 2>&1; then
    echo "OK: systemd-logind responde. Las apps modernas ya no necesitan ConsoleKit."
elif gdbus introspect --system --dest org.freedesktop.ConsoleKit --object-path /org/freedesktop/ConsoleKit/Manager >/dev/null 2>&1; then
    echo "OK: ConsoleKit responde."
else
    echo "AVISO: ni logind ni ConsoleKit responden todavia."
fi

echo ">> Listo. Cierra sesion y vuelve a entrar (o reinicia) para aplicar los cambios."
