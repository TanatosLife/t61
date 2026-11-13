#!/usr/bin/env bash
# =============================================================================
#  arreglar-sesion.sh
#  Corrige el aviso:
#    GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown:
#    The name org.freedesktop.ConsoleKit was not provided by any .service files
#
#  En antiX Core (Debian 12 + sysvinit) las sesiones las registra ELOGIND.
#  Si la sesion no queda registrada, algunos programas prueban ConsoleKit
#  (inexistente) y muestran ese error; ademas polkit trata tu sesion como
#  "no activa" y niega permisos (red, USB, apagado...).
#
#  MODO 1 - reparar (como root, desde una TTY):
#      bash arreglar-sesion.sh [usuario]          # usuario por defecto: cronos
#
#  MODO 2 - diagnosticar (como usuario normal, DENTRO de la sesion grafica):
#      bash arreglar-sesion.sh --diagnostico
# =============================================================================
set -u
umask 022
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_R=$'\e[1;31m'; C_B=$'\e[1;34m'; C_0=$'\e[0m'
info() { echo "${C_B}==>${C_0} $*"; }
ok()   { echo "${C_G} ok${C_0} $*"; }
warn() { echo "${C_Y} !!${C_0} $*"; }
die()  { echo "${C_R}ERROR:${C_0} $*"; exit 1; }

# =============================================================================
#  MODO 2: diagnostico (usuario normal, dentro de X)
# =============================================================================
diagnostico() {
  [ "$(id -u)" -ne 0 ] || die "El diagnostico se ejecuta como usuario normal, dentro de la sesion grafica."
  [ -n "${DISPLAY:-}" ] || die "Abre una terminal DENTRO de bspwm (super+Enter) y ejecutalo alli."

  info "Entorno de la sesion"
  echo "  XDG_SESSION_ID  = ${XDG_SESSION_ID:-<VACIO>}"
  echo "  XDG_RUNTIME_DIR = ${XDG_RUNTIME_DIR:-<VACIO>}"
  echo "  DBUS_SESSION    = ${DBUS_SESSION_BUS_ADDRESS:-<VACIO>}"

  info "¿elogind conoce este proceso como parte de una sesion?"
  if command -v dbus-send >/dev/null; then
    dbus-send --system --print-reply --dest=org.freedesktop.login1 \
      /org/freedesktop/login1 org.freedesktop.login1.Manager.GetSessionByPID \
      uint32:$$ 2>&1 | tail -n 2 | sed 's/^/  /'
  fi

  info "Sesiones registradas"
  loginctl list-sessions 2>&1 | sed 's/^/  /'
  if [ -n "${XDG_SESSION_ID:-}" ]; then
    loginctl show-session "$XDG_SESSION_ID" -p Active -p State -p Type -p Seat 2>&1 | sed 's/^/  /'
  fi

  info "Procesos clave"
  local p
  for p in elogind dbus-daemon polkitd; do
    pgrep -x "$p" >/dev/null && echo "  [ok]  $p" || echo "  [NO]  $p"
  done

  info "Buscando que programa muestra el aviso (se reinician 4 programas de la sesion)"
  local culpables=() args
  for p in lxpolkit nm-applet blueman-applet udiskie; do
    command -v "$p" >/dev/null || continue
    args=""; [ "$p" = udiskie ] && args="--tray"
    pkill -x "$p" 2>/dev/null; sleep 0.3
    rm -f "/tmp/diag-$p.err"
    setsid -f sh -c "exec $p $args 2>/tmp/diag-$p.err" >/dev/null 2>&1
  done
  sleep 4
  for p in lxpolkit nm-applet blueman-applet udiskie; do
    [ -f "/tmp/diag-$p.err" ] || continue
    if grep -qi 'consolekit' "/tmp/diag-$p.err"; then culpables+=("$p"); fi
  done
  if [ "${#culpables[@]}" -gt 0 ]; then
    warn "Programa(s) que muestran el aviso: ${culpables[*]}"
  else
    echo "  Ninguno de los 4 lo muestra. Revisa tambien: pcmanfm, pavucontrol, xss-lock."
    echo "  Mira los mensajes de arranque con:  cat ~/.xsession-errors 2>/dev/null | grep -i consolekit"
  fi

  echo
  if [ -z "${XDG_SESSION_ID:-}" ]; then
    warn "XDG_SESSION_ID esta vacio: la sesion NO esta registrada en elogind."
    echo "  Ejecuta como root el MODO 1 (bash arreglar-sesion.sh), reinicia y entra de nuevo."
  else
    ok "La sesion esta registrada (id $XDG_SESSION_ID)."
  fi
  exit 0
}

[ "${1:-}" = "--diagnostico" ] && diagnostico

# =============================================================================
#  MODO 1: reparar (root)
# =============================================================================
[ "$(id -u)" -eq 0 ] || die "Ejecuta como root:  su -  y luego  bash $0   (o usa --diagnostico como usuario)"
USUARIO="${1:-cronos}"
id "$USUARIO" >/dev/null 2>&1 || die "El usuario '$USUARIO' no existe."
HOME_DIR="$(getent passwd "$USUARIO" | cut -d: -f6)"
LOG=/var/log/arreglar-sesion.log
BK="/root/backup-sesion-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"
exec > >(tee -a "$LOG") 2>&1
bk() { [ -e "$1" ] && cp -a --parents "$1" "$BK" 2>/dev/null; return 0; }
tiene() { dpkg -s "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- 1. Estado --
info "1/5  Estado actual"
for p in elogind libpam-elogind dbus polkitd pkexec policykit-1 lxpolkit; do
  tiene "$p" && echo "  [instalado] $p" || echo "  [falta]     $p"
done
tiene consolekit && warn "consolekit esta instalado: puede chocar con elogind (considera: apt purge consolekit)"
pgrep -x elogind >/dev/null && echo "  [ok] elogind en ejecucion" || warn "elogind NO esta en ejecucion"
pgrep -x dbus-daemon >/dev/null && echo "  [ok] dbus en ejecucion" || warn "dbus NO esta en ejecucion"
grep -qs 'pam_elogind' /etc/pam.d/common-session \
  && echo "  [ok] pam_elogind en common-session" || warn "pam_elogind NO esta en /etc/pam.d/common-session"

# ------------------------------------------------------------- 2. Paquetes ---
info "2/5  Paquetes (con simulacion previa para no romper nada)"
FALTAN=()
for p in elogind libpam-elogind dbus dbus-x11; do tiene "$p" || FALTAN+=("$p"); done
if [ "${#FALTAN[@]}" -gt 0 ]; then
  apt-get update >>"$LOG" 2>&1
  QUITA="$(apt-get -s install --no-install-recommends "${FALTAN[@]}" 2>/dev/null | grep '^Remv' || true)"
  if [ -n "$QUITA" ]; then
    warn "Instalar ${FALTAN[*]} haria que apt ELIMINE paquetes. No lo hago automaticamente:"
    echo "$QUITA" | sed 's/^/     /'
    echo "     Envia esta lista y lo resolvemos con cuidado."
  else
    apt-get install -y --no-install-recommends "${FALTAN[@]}" >>"$LOG" 2>&1 \
      && ok "instalados: ${FALTAN[*]}" || warn "fallo la instalacion (mira $LOG)"
  fi
else
  ok "paquetes base presentes"
fi
tiene polkitd || tiene policykit-1 || warn "no hay polkit instalado (apt install polkitd pkexec)"

# ------------------------------------------------------------- 3. Servicios --
info "3/5  Servicios dbus y elogind"
for s in dbus elogind; do
  if [ -x "/etc/init.d/$s" ]; then
    update-rc.d "$s" defaults >/dev/null 2>&1
    service "$s" start >/dev/null 2>&1
    ok "servicio $s habilitado e iniciado"
  else
    warn "no existe /etc/init.d/$s (¿usas runit? habilita el servicio $s a mano)"
  fi
done
sleep 1
pgrep -x elogind >/dev/null && ok "elogind activo" || warn "elogind sigue sin arrancar: mira  service elogind start"

# ------------------------------------------------------------------ 4. PAM ---
info "4/5  PAM: registro de sesion en el inicio de sesion"
if ! grep -qs 'pam_elogind' /etc/pam.d/common-session; then
  bk /etc/pam.d/common-session
  if [ -f /usr/share/pam-configs/elogind ]; then
    pam-auth-update --enable elogind >>"$LOG" 2>&1
  fi
  grep -qs 'pam_elogind' /etc/pam.d/common-session || \
    echo 'session optional pam_elogind.so' >> /etc/pam.d/common-session
  ok "pam_elogind habilitado"
else
  ok "pam_elogind ya estaba habilitado"
fi
if ! grep -Eqs '^@include[[:space:]]+common-session([[:space:]]|$)' /etc/pam.d/login \
   && ! grep -qs 'pam_elogind' /etc/pam.d/login; then
  bk /etc/pam.d/login
  echo 'session optional pam_elogind.so' >> /etc/pam.d/login
  ok "pam_elogind agregado a /etc/pam.d/login"
fi

# ------------------------------------------- 5. Agente de polkit en bspwmrc ---
info "5/5  Inicio del agente de polkit"
RC="$HOME_DIR/.config/bspwm/bspwmrc"
if [ -f "$RC" ]; then
  if grep -E '^run .*polkit' "$RC" | grep -qv 'XDG_SESSION_ID'; then
    bk "$RC"
    awk '$0 ~ /^run .*polkit/ && $0 !~ /XDG_SESSION_ID/ { print "[ -n \"${XDG_SESSION_ID:-}\" ] && " $0; next } { print }' \
      "$RC" > "$RC.nuevo" && cat "$RC.nuevo" > "$RC" && rm -f "$RC.nuevo"
    ok "el agente de polkit solo arranca si la sesion esta registrada"
  else
    ok "bspwmrc ya estaba ajustado (o no usa agente de polkit)"
  fi
  chown "$USUARIO:$(id -gn "$USUARIO")" "$RC"; chmod 755 "$RC"
else
  warn "no existe $RC (ejecuta antes setup-t61.sh)"
fi

# ------------------------------------------------------------------ Resumen --
echo
echo "${C_G}============================  LISTO  ============================${C_0}"
echo "IMPORTANTE: la sesion se registra al INICIAR SESION. Reinicia el equipo:"
echo "    reboot"
echo "Entra con '$USUARIO' y, en una terminal de bspwm, comprueba:"
echo "    echo \$XDG_SESSION_ID                    (debe mostrar un numero)"
echo "    loginctl show-session \$XDG_SESSION_ID -p Active -p State     (Active=yes)"
echo "Si el aviso persiste, dentro de la sesion ejecuta:"
echo "    bash arreglar-sesion.sh --diagnostico"
echo "y envia la salida completa."
echo "Backups: $BK    Log: $LOG"
