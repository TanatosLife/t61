#!/usr/bin/env bash
# =============================================================================
#  estabilizar-t61.sh
#  Repara y estabiliza elogind / polkit / sesion en antiX Core (Debian 12,
#  sysvinit) + bspwm. ThinkPad T61.
#
#  Resuelve:
#    - GDBus.Error ... org.freedesktop.ConsoleKit was not provided by any .service
#    - GDBus.Error ... Unable to lookup session information for process 'NNN'
#    - permisos de red / USB / audio / apagado denegados
#
#  Causa tipica: libpam-systemd (o consolekit) desplazo a libpam-elogind, asi
#  que el login ya no registra la sesion en elogind.
#
#  USO
#    Reparar (como root, desde una TTY):
#        bash estabilizar-t61.sh                  # usuario por defecto: cronos
#        bash estabilizar-t61.sh otro_usuario
#    Opciones:
#        --xwrapper        X con wrapper (solo si X no inicia despues)
#        --purge-systemd   ademas quita el paquete systemd (opcional)
#    Diagnostico (como usuario normal, DENTRO de bspwm):
#        bash estabilizar-t61.sh --diagnostico
#
#  Es re-ejecutable. Backups en /root/backup-estabilizar-*. Log en
#  /var/log/estabilizar-t61.log
# =============================================================================
set -u
umask 022
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive
export PATH="$PATH:/usr/sbin:/sbin"

LOG=/var/log/estabilizar-t61.log
TARGET_USER=""
XWRAPPER=no
PURGE_SYSTEMD=no
MODE=fix
PROBLEMAS=()

C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_R=$'\e[1;31m'; C_B=$'\e[1;34m'; C_0=$'\e[0m'
info() { echo "${C_B}==>${C_0} $*"; }
ok()   { echo "${C_G} ok${C_0} $*"; }
warn() { echo "${C_Y} !!${C_0} $*"; }
die()  { echo "${C_R}ERROR:${C_0} $*"; exit 1; }

for a in "$@"; do
  case "$a" in
    --diagnostico)   MODE=diag ;;
    --xwrapper)      XWRAPPER=yes ;;
    --purge-systemd) PURGE_SYSTEMD=yes ;;
    -h|--help)       sed -n '2,31p' "$0"; exit 0 ;;
    -*)              die "opcion desconocida: $a" ;;
    *)               TARGET_USER="$a" ;;
  esac
done

# =============================================================================
#  MODO DIAGNOSTICO (usuario normal, dentro de la sesion grafica)
# =============================================================================
diagnostico() {
  [ "$(id -u)" -ne 0 ] || die "El diagnostico se ejecuta como usuario normal, dentro de bspwm."
  info "Entorno de la sesion"
  echo "  XDG_SESSION_ID  = ${XDG_SESSION_ID:-<VACIO>}"
  echo "  XDG_RUNTIME_DIR = ${XDG_RUNTIME_DIR:-<VACIO>}"
  echo "  DBUS_SESSION    = ${DBUS_SESSION_BUS_ADDRESS:-<VACIO>}"
  info "Procesos clave"
  local p
  for p in dbus-daemon elogind polkitd NetworkManager; do
    pgrep -x "$p" >/dev/null && echo "  [ok] $p" || echo "  [NO] $p"
  done
  info "Paquetes que no deben estar"
  for p in libpam-systemd consolekit libpam-ck-connector systemd-sysv; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed' \
      && echo "  [PRESENTE] $p" || echo "  [ausente]  $p"
  done
  info "elogind reconoce este proceso?"
  dbus-send --system --print-reply --dest=org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager.GetSessionByPID uint32:$$ 2>&1 | tail -n 2 | sed 's/^/  /'
  info "Sesiones"
  loginctl list-sessions 2>&1 | sed 's/^/  /'
  [ -n "${XDG_SESSION_ID:-}" ] && \
    loginctl show-session "$XDG_SESSION_ID" -p Active -p State -p Type -p Seat 2>&1 | sed 's/^/  /'
  info "polkit: permiso de montar discos para esta sesion"
  pkcheck --action-id org.freedesktop.udisks2.filesystem-mount --process $$ >/dev/null 2>&1
  case $? in 0) echo "  autorizado" ;; 1) echo "  NO autorizado" ;; *) echo "  requiere autenticacion" ;; esac
  info "PAM"
  grep -s pam_elogind /etc/pam.d/common-session | sed 's/^/  /' || true
  echo
  if [ -z "${XDG_SESSION_ID:-}" ]; then
    warn "XDG_SESSION_ID vacio: la sesion NO esta registrada. Ejecuta la reparacion como root, reinicia y entra por TTY1."
  else
    ok "Sesion registrada (id $XDG_SESSION_ID)."
  fi
  exit 0
}
[ "$MODE" = diag ] && diagnostico

# =============================================================================
#  MODO REPARACION (root)
# =============================================================================
[ "$(id -u)" -eq 0 ] || die "Ejecuta como root:  su -  y luego  bash $0"
command -v apt-get >/dev/null || die "Este script es para antiX/Debian (apt)."

[ -z "$TARGET_USER" ] && { id cronos >/dev/null 2>&1 && TARGET_USER=cronos || TARGET_USER="$(getent passwd 1000 | cut -d: -f1)"; }
[ -n "$TARGET_USER" ] && id "$TARGET_USER" >/dev/null 2>&1 || die "No encuentro el usuario. Uso: bash $0 NOMBRE_USUARIO"
[ "$TARGET_USER" = root ] && die "Usa un usuario normal, no root."

exec > >(tee -a "$LOG") 2>&1

HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
USER_GRP="$(id -gn "$TARGET_USER")"
BK="/root/backup-estabilizar-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"

bk() { [ -e "$1" ] && cp -a --parents "$1" "$BK" 2>/dev/null; return 0; }
pkg_inst() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed'; }
elogind_ok() {
  dbus-send --system --print-reply --dest=org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1
}
svc_enable() {
  if [ -x "/etc/init.d/$1" ]; then
    update-rc.d "$1" defaults >/dev/null 2>&1
    service "$1" start >/dev/null 2>&1
    ok "servicio $1 habilitado"
  else
    warn "no existe /etc/init.d/$1"; return 1
  fi
}
# Instala/purga SIMULANDO antes: si apt quiere eliminar algo fuera de la lista
# permitida, no toca nada y lo avisa.
safe_apt() {   # safe_apt <install|purge> <regex_permitido> <paquetes...>
  local act="$1" allow="$2"; shift 2
  local opt="" sim remv p bad=""
  [ "$act" = install ] && opt="--no-install-recommends"
  if ! sim="$(apt-get -s $opt "$act" "$@" 2>&1)"; then
    warn "apt no puede resolver: $*"; echo "$sim" | tail -n 8 | sed 's/^/     /'; return 1
  fi
  remv="$(echo "$sim" | awk '/^Remv /{print $2}')"
  for p in $remv; do echo "${p%%:*}" | grep -Eq "$allow" || bad="$bad $p"; done
  if [ -n "$bad" ]; then
    warn "apt eliminaria paquetes que NO estan permitidos:$bad"
    warn "No hago el cambio. Envia esta salida para resolverlo con cuidado."
    return 1
  fi
  [ -n "$remv" ] && info "apt quitara (permitido): $(echo $remv)"
  apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confold "$@" >>"$LOG" 2>&1 \
    && return 0
  apt-get "$act" -y "$@" >>"$LOG" 2>&1
}

info "Usuario: $TARGET_USER  (home: $HOME_DIR)"

# ---------------------------------------------------------------- 1. Estado --
info "1/10  Estado inicial"
PID1="$(cat /proc/1/comm 2>/dev/null)"
INIT_REAL="$(readlink -f /sbin/init 2>/dev/null)"
echo "  PID 1: $PID1    /sbin/init -> $INIT_REAL"
[ "$PID1" = systemd ] && die "PID 1 es systemd: este script es solo para sysvinit (antiX Core)."
for p in elogind libpam-elogind libpam-systemd systemd systemd-sysv consolekit libpam-ck-connector \
         sysvinit-core dbus polkitd pkexec; do
  pkg_inst "$p" && echo "  [instalado] $p" || echo "  [ausente]   $p"
done
dpkg --configure -a >>"$LOG" 2>&1 || warn "dpkg --configure -a reporto avisos (mira $LOG)"
apt-get update >>"$LOG" 2>&1 || warn "apt-get update fallo (hay internet?)"

# ------------------------------------------------- 2. El init no debe cambiar --
info "2/10  Comprobando que el arranque siga siendo sysvinit"
if pkg_inst systemd-sysv || echo "$INIT_REAL" | grep -q systemd; then
  warn "systemd-sysv esta instalado: en el proximo arranque entraria systemd y elogind dejaria de funcionar"
  safe_apt install '^(systemd-sysv)$' sysvinit-core && ok "sysvinit-core restaurado" \
    || PROBLEMAS+=("init (sysvinit-core)")
else
  ok "init correcto (sysvinit)"
fi

# --------------------------------------------- 3. Quitar ConsoleKit y similares --
info "3/10  Quitando ConsoleKit"
CK="$(dpkg -l 2>/dev/null | awk '/^(ii|rc)/ && $2 ~ /^(consolekit|libck-connector|libpam-ck-connector)/ {print $2}')"
if [ -n "$CK" ]; then
  service console-kit-daemon stop >/dev/null 2>&1
  pkill -f console-kit-daemon 2>/dev/null
  apt-get purge -y $CK >>"$LOG" 2>&1 && ok "purgado: $(echo $CK)" || warn "no pude purgar: $(echo $CK)"
else
  ok "ConsoleKit no esta instalado"
fi

# ------------------------------------------ 4. elogind en lugar de libpam-systemd --
info "4/10  Instalando elogind y quitando libpam-systemd"
safe_apt install '^(libpam-systemd|libnss-systemd|systemd-sysv|dbus-user-session|systemd-timesyncd)$' \
  elogind libpam-elogind dbus dbus-x11 polkitd pkexec \
  && ok "elogind + libpam-elogind + polkit listos" \
  || { PROBLEMAS+=("instalacion de elogind"); die "No se pudo instalar elogind (ver aviso arriba)."; }

if [ "$PURGE_SYSTEMD" = yes ] && pkg_inst systemd; then
  safe_apt purge '^(systemd|libpam-systemd|libnss-systemd|systemd-timesyncd|systemd-sysv|dbus-user-session|libsystemd-shared)$' \
    systemd libpam-systemd libnss-systemd && ok "paquete systemd quitado" || warn "se deja el paquete systemd (inofensivo)"
fi

# Evitar que vuelvan a colarse en una actualizacion futura
cat > /etc/apt/preferences.d/99-sin-systemd-ck <<'EOF'
# antiX Core usa sysvinit + elogind. Estos paquetes lo romperian.
Package: libpam-systemd systemd-sysv libnss-systemd dbus-user-session consolekit libpam-ck-connector
Pin: release *
Pin-Priority: -1
EOF
chmod 644 /etc/apt/preferences.d/99-sin-systemd-ck
ok "bloqueados en apt: libpam-systemd, systemd-sysv, consolekit..."

# nsswitch: quitar la entrada "systemd" si ya no existe libnss-systemd
if ! pkg_inst libnss-systemd && grep -Eq '^(passwd|group|shadow|gshadow):.*[[:space:]]systemd([[:space:]]|$)' /etc/nsswitch.conf; then
  bk /etc/nsswitch.conf
  sed -i -E '/^(passwd|group|shadow|gshadow):/ s/[[:space:]]+systemd([[:space:]]|$)/\1/' /etc/nsswitch.conf
  ok "nsswitch.conf limpiado"
fi

# --------------------------------------------------------------- 5. PAM -------
info "5/10  PAM: la sesion debe registrarse en elogind al hacer login"
for f in /etc/pam.d/*; do
  [ -f "$f" ] || continue
  if grep -Eq 'pam_(ck_connector|systemd)\.so' "$f"; then
    bk "$f"; sed -i -E '/pam_(ck_connector|systemd)\.so/d' "$f"
    ok "quitada referencia obsoleta en $f"
  fi
done
if ! grep -qs 'pam_elogind\.so' /etc/pam.d/common-session; then
  bk /etc/pam.d/common-session
  [ -f /usr/share/pam-configs/elogind ] && pam-auth-update --enable elogind >>"$LOG" 2>&1
  grep -qs 'pam_elogind\.so' /etc/pam.d/common-session || \
    echo 'session optional pam_elogind.so' >> /etc/pam.d/common-session
  ok "pam_elogind habilitado en common-session"
else
  ok "pam_elogind ya estaba en common-session"
fi
if ! grep -Eqs '^(@include|session[[:space:]]+include)[[:space:]]+common-session([[:space:]]|$)' /etc/pam.d/login \
   && ! grep -qs 'pam_elogind\.so' /etc/pam.d/login; then
  bk /etc/pam.d/login
  echo 'session optional pam_elogind.so' >> /etc/pam.d/login
  ok "pam_elogind agregado a /etc/pam.d/login"
fi

# ----------------------------------------------------- 6. Servicios y cgroup ---
info "6/10  Servicios dbus + elogind"
svc_enable dbus
svc_enable elogind || PROBLEMAS+=("falta /etc/init.d/elogind")
service elogind restart >/dev/null 2>&1; sleep 2
if ! elogind_ok; then
  warn "elogind no responde; reviso cgroups (elogind los necesita)"
  if ! mountpoint -q /sys/fs/cgroup 2>/dev/null; then
    mkdir -p /sys/fs/cgroup
    if mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null; then
      ok "cgroup2 montado en /sys/fs/cgroup"
      bk /etc/fstab
      grep -Eq '^\S+\s+/sys/fs/cgroup\s' /etc/fstab || \
        echo 'cgroup2 /sys/fs/cgroup cgroup2 defaults 0 0' >> /etc/fstab
    else
      warn "no pude montar cgroup2 (kernel sin soporte?)"
    fi
  else
    echo "  /sys/fs/cgroup ya esta montado ($(stat -fc %T /sys/fs/cgroup 2>/dev/null))"
  fi
  service elogind restart >/dev/null 2>&1; sleep 2
fi
if elogind_ok; then ok "elogind responde en D-Bus"
else
  warn "elogind sigue sin responder"
  PROBLEMAS+=("elogind no responde")
  ps aux | grep -E '[e]logind|[d]bus-daemon' | sed 's/^/     /'
fi

# --------------------------------------------------------------- 7. polkit -----
info "7/10  Reglas de polkit (red, USB, apagado) y grupos"
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/50-local-usuario.rules <<'EOF'
// Reglas locales (antiX Core + bspwm). Sirven aunque la sesion no figure activa.
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("netdev") &&
        action.id.indexOf("org.freedesktop.NetworkManager.") === 0) {
        return polkit.Result.YES;
    }
});
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("plugdev") &&
        action.id.match(/^org\.freedesktop\.udisks2\.(filesystem-mount|filesystem-mount-other-seat|filesystem-unmount-others|encrypted-unlock|eject-media|power-off-drive|loop-setup)$/)) {
        return polkit.Result.YES;
    }
});
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("sudo") &&
        action.id.match(/^org\.freedesktop\.login1\.(power-off|reboot|suspend|hibernate)/)) {
        return polkit.Result.YES;
    }
});
EOF
chmod 644 /etc/polkit-1/rules.d/50-local-usuario.rules
ok "reglas polkit instaladas"

for g in sudo audio video render netdev plugdev bluetooth lp cdrom; do
  getent group "$g" >/dev/null || continue
  id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$g" || { usermod -aG "$g" "$TARGET_USER"; ok "agregado al grupo $g"; }
done

# ------------------------------------------------ 8. Permisos y red de /etc ----
info "8/10  Permisos de archivos, udev y NetworkManager"
for f in /etc/X11/xorg.conf.d/*.conf /etc/sysctl.d/99-t61-*.conf /etc/modprobe.d/t61-*.conf \
         /etc/security/limits.d/10-nocore.conf /etc/NetworkManager/conf.d/*.conf /etc/tlp.d/*.conf \
         /etc/apt/apt.conf.d/20auto-upgrades /etc/ssh/sshd_config.d/99-hardening.conf \
         /etc/fstab /etc/network/interfaces /etc/default/keyboard; do
  [ -f "$f" ] && chmod 644 "$f" && chown root:root "$f"
done
chmod 755 /usr/local/bin/perfmode /usr/local/sbin/perfmode-set 2>/dev/null

if grep -qE '^UMASK\s+027' /etc/login.defs; then
  bk /etc/login.defs
  sed -i -E 's/^UMASK\s+.*/UMASK           022/' /etc/login.defs
  ok "UMASK a 022 (tu carpeta personal sigue en 750)"
fi
if [ -x /usr/local/sbin/perfmode-set ]; then
  echo "$TARGET_USER ALL=(root) NOPASSWD: /usr/local/sbin/perfmode-set" > /etc/sudoers.d/perfmode
  chmod 440 /etc/sudoers.d/perfmode
  visudo -cf /etc/sudoers.d/perfmode >/dev/null || { rm -f /etc/sudoers.d/perfmode; warn "sudoers invalido, eliminado"; }
fi

cat > /etc/udev/rules.d/70-local-permisos.rules <<'EOF'
KERNEL=="rfkill", SUBSYSTEM=="misc", GROUP="netdev", MODE="0660"
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
ACTION=="add", SUBSYSTEM=="leds", KERNEL=="*::kbd_backlight", RUN+="/bin/chgrp video /sys/class/leds/%k/brightness", RUN+="/bin/chmod g+w /sys/class/leds/%k/brightness"
EOF
chmod 644 /etc/udev/rules.d/70-local-permisos.rules
udevadm control --reload-rules 2>/dev/null; udevadm trigger 2>/dev/null
rfkill unblock all 2>/dev/null

if [ -f /etc/NetworkManager/NetworkManager.conf ] && grep -q 'managed=false' /etc/NetworkManager/NetworkManager.conf; then
  bk /etc/NetworkManager/NetworkManager.conf
  sed -i 's/managed=false/managed=true/' /etc/NetworkManager/NetworkManager.conf
  ok "NetworkManager administrara las interfaces"
fi
if [ -f /etc/network/interfaces ] && grep -Eq '^\s*(auto|allow-hotplug|iface)\s+(eth|en|wl)' /etc/network/interfaces; then
  bk /etc/network/interfaces
  awk '/^[[:space:]]*(auto|allow-hotplug|iface|wpa-|wireless-)/ && $0 !~ /[[:space:]]lo([[:space:]]|$)/ {print "#" $0; next} {print}' \
     /etc/network/interfaces > /tmp/interfaces.new && install -m 644 /tmp/interfaces.new /etc/network/interfaces
  rm -f /tmp/interfaces.new
  ok "interfaces de /etc/network/interfaces comentadas"
fi
pkg_inst connman && warn "connman compite con NetworkManager (apt purge connman)"
svc_enable network-manager
svc_enable bluetooth

# --------------------------------------------------- 9. Archivos del usuario ----
info "9/10  Carpeta personal, .xinitrc y bspwmrc"
chown "$TARGET_USER:$USER_GRP" "$HOME_DIR"; chmod 750 "$HOME_DIR"
n=$(find "$HOME_DIR" -xdev ! -user "$TARGET_USER" 2>/dev/null | wc -l)
if [ "$n" -gt 0 ]; then
  find "$HOME_DIR" -xdev ! -user "$TARGET_USER" -exec chown -h "$TARGET_USER:$USER_GRP" {} + 2>/dev/null
  ok "corregidos $n archivos que no eran tuyos"
fi
for d in "$HOME_DIR/.config" "$HOME_DIR/.local" "$HOME_DIR/.cache"; do
  [ -d "$d" ] && chown -R "$TARGET_USER:$USER_GRP" "$d"
done

[ -f "$HOME_DIR/.xinitrc" ] && cp -a "$HOME_DIR/.xinitrc" "$BK/xinitrc.bak"
cat > "$HOME_DIR/.xinitrc" <<'EOF'
#!/bin/sh
[ -f "$HOME/.Xresources" ] && xrdb -merge "$HOME/.Xresources"
export XDG_CURRENT_DESKTOP=bspwm
export mesa_glthread=true
# Respaldo: si elogind no creo XDG_RUNTIME_DIR, lo creamos (pipewire lo necesita)
if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "$XDG_RUNTIME_DIR" ]; then
  export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
  mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
fi
exec dbus-launch --exit-with-session bspwm
EOF
chown "$TARGET_USER:$USER_GRP" "$HOME_DIR/.xinitrc"; chmod 755 "$HOME_DIR/.xinitrc"

RC="$HOME_DIR/.config/bspwm/bspwmrc"
if [ -f "$RC" ]; then
  if ! grep -q 'dbus-update-activation-environment' "$RC"; then
    bk "$RC"
    # Pasa DISPLAY y XDG_SESSION_ID a los servicios que D-Bus activa (polkit, udisks...)
    awk '{print} /^run\(\) \{/ && !d {print "command -v dbus-update-activation-environment >/dev/null 2>&1 && dbus-update-activation-environment --all"; d=1}' \
      "$RC" > "$RC.nuevo" && cat "$RC.nuevo" > "$RC"; rm -f "$RC.nuevo"
    ok "bspwmrc: entorno exportado a D-Bus"
  fi
  chown "$TARGET_USER:$USER_GRP" "$RC"; chmod 755 "$RC"
else
  warn "no existe $RC (ejecuta antes setup-t61.sh)"
fi
chmod 755 "$HOME_DIR"/.config/polybar/launch.sh "$HOME_DIR"/.config/polybar/scripts/*.sh \
          "$HOME_DIR"/.local/bin/* 2>/dev/null

# Agente polkit
if ! command -v lxpolkit >/dev/null 2>&1 && ! pkg_inst policykit-1-gnome; then
  apt-get install -y --no-install-recommends lxpolkit >>"$LOG" 2>&1 || warn "no se pudo instalar lxpolkit"
fi

if [ "$XWRAPPER" = yes ]; then
  apt-get install -y --no-install-recommends xserver-xorg-legacy >>"$LOG" 2>&1
  bk /etc/X11/Xwrapper.config
  printf 'allowed_users=console\nneeds_root_rights=yes\n' > /etc/X11/Xwrapper.config
  chmod 644 /etc/X11/Xwrapper.config
  ok "Xwrapper configurado"
fi

# ---------------------------------------------------------- 10. Verificacion ----
info "10/10  Verificacion"
no_pkg() { ! pkg_inst "$1"; }
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "  [ok] $d"; else echo "  [NO] $d"; PROBLEMAS+=("$d"); fi; }
chk "sysvinit es el init"               test "$(readlink -f /sbin/init | grep -c systemd)" = 0
chk "elogind en ejecucion"              pgrep -x elogind
chk "elogind responde en D-Bus"         elogind_ok
chk "libpam-elogind instalado"          pkg_inst libpam-elogind
chk "pam_elogind en common-session"     grep -qs 'pam_elogind\.so' /etc/pam.d/common-session
chk "libpam-systemd ausente"            no_pkg libpam-systemd
chk "consolekit ausente"                no_pkg consolekit
chk "polkit instalado"                  pkg_inst polkitd
chk "regla polkit presente"             test -r /etc/polkit-1/rules.d/50-local-usuario.rules
echo "--- Denegaciones AppArmor recientes:"
dmesg 2>/dev/null | grep -i 'apparmor="DENIED"' | tail -n 5 || true

echo
if [ "${#PROBLEMAS[@]}" -eq 0 ]; then
  echo "${C_G}========================  LISTO  ========================${C_0}"
else
  echo "${C_Y}=============  LISTO, CON PENDIENTES  =============${C_0}"
  for p in "${PROBLEMAS[@]}"; do echo "   - $p"; done
fi
cat <<EOF

AHORA: reinicia (la sesion solo se registra al iniciar sesion):
    reboot
Entra por la TTY1 con '$TARGET_USER' (X + bspwm arrancan solos). En una terminal de bspwm:
    echo \$XDG_SESSION_ID          # debe mostrar un numero
    bash $(basename "$0") --diagnostico
Si X no inicia tras reiniciar:   bash $(basename "$0") $TARGET_USER --xwrapper
Si algo falla, envia: la salida de --diagnostico y  tail -n 60 $LOG
Backups: $BK    Log: $LOG
EOF
