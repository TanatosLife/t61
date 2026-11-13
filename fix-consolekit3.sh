#!/usr/bin/env bash
# Deja ConsoleKit + systemd-logind funcionando a la vez y registra la sesion en ambos.
# Soluciona:
#   - ServiceUnknown: org.freedesktop.ConsoleKit not provided by any .service files
#   - Unable to lookup session information for process 'XXXX'
#
# Uso: sudo bash fix-consolekit3.sh

set -u

if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

. /etc/os-release
DISTRO="${ID:-unknown} ${ID_LIKE:-}"
echo ">> Distribucion: $DISTRO"

echo ">> 1) Instalando ConsoleKit + conector PAM..."
case "$DISTRO" in
    *debian*|*ubuntu*|*mint*)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        if ! apt-get install -y consolekit libpam-ck-connector libpam-systemd dbus dbus-x11; then
            echo "!! El paquete consolekit NO existe en tu version de la distro."
            echo "!! Ve a la seccion 'Si consolekit no esta disponible' al final."
            NOCK=1
        fi
        ;;
    *arch*|*manjaro*)
        echo "En Arch, consolekit esta en AUR (consolekit / consolekit2). Instalalo con tu helper AUR."
        NOCK=1
        ;;
    *fedora*|*rhel*|*centos*)
        dnf install -y ConsoleKit ConsoleKit-x11 2>/dev/null || NOCK=1
        ;;
    *)
        echo "Instala consolekit y pam_ck_connector manualmente."
        NOCK=1
        ;;
esac
NOCK="${NOCK:-0}"

if [ "$NOCK" = "0" ]; then
    echo ">> 2) Verificando pam_ck_connector en PAM..."
    if ! grep -rqs "pam_ck_connector" /etc/pam.d/; then
        echo "session optional pam_ck_connector.so nox11" >> /etc/pam.d/common-session
        echo "   Agregada linea a /etc/pam.d/common-session"
    else
        echo "   Ya esta configurado."
    fi

    echo ">> 3) Activando servicios..."
    systemctl enable --now dbus 2>/dev/null || true
    systemctl enable --now systemd-logind 2>/dev/null || true
    systemctl enable --now console-kit-daemon 2>/dev/null || true
    systemctl restart dbus 2>/dev/null || true
fi

echo
echo ">> Diagnostico (para saber quien llama a ConsoleKit):"
echo "--- Servicio ConsoleKit en D-Bus:"
ls /usr/share/dbus-1/system-services/ 2>/dev/null | grep -i consolekit || echo "(no hay .service de ConsoleKit)"
echo "--- Sesiones en logind:"
loginctl list-sessions 2>/dev/null || true
echo "--- Sesiones en ConsoleKit:"
ck-list-sessions 2>/dev/null || echo "(ck-list-sessions no disponible)"
echo "--- Entorno de escritorio: ${XDG_CURRENT_DESKTOP:-desconocido} / ${DESKTOP_SESSION:-desconocido}"

cat <<'EOF'

>> Ahora CIERRA SESION y vuelve a entrar (o reinicia). Es obligatorio:
   la sesion solo se registra en ConsoleKit en el momento del login.

Si consolekit no esta disponible en tu distro:
  El programa que lo llama es antiguo. Opciones:
  - Actualizalo o reemplazalo por una version que use logind.
  - Averigua cual es ejecutandolo desde una terminal y revisando:
      journalctl -b | grep -i -E "consolekit|ck-"
      sudo dbus-monitor --system "destination=org.freedesktop.ConsoleKit"
EOF
