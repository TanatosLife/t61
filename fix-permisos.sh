#!/usr/bin/env bash
# =============================================================================
#  fix-permisos.sh  -  Arregla permisos de red, USB, audio, bluetooth, brillo...
#  antiX Core + bspwm (ThinkPad T61)
#
#  Uso (como root):
#      bash fix-permisos.sh                 # usuario: cronos
#      bash fix-permisos.sh otro_usuario    # otro usuario
#      bash fix-permisos.sh cronos --xwrapper   # extra: X con wrapper (si X no inicia)
#
#  Es re-ejecutable. Log: /var/log/fix-permisos.log
# =============================================================================
set -u
umask 022                      # clave: los archivos de /etc deben ser legibles por los servicios
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

LOG=/var/log/fix-permisos.log
TARGET_USER="cronos"
XWRAPPER=no
for a in "$@"; do
  case "$a" in
    --xwrapper) XWRAPPER=yes ;;
    -*) ;;
    *) TARGET_USER="$a" ;;
  esac
done

C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_R=$'\e[1;31m'; C_B=$'\e[1;34m'; C_0=$'\e[0m'
info() { echo "${C_B}==>${C_0} $*"; }
ok()   { echo "${C_G} ok${C_0} $*"; }
warn() { echo "${C_Y} !!${C_0} $*"; }
die()  { echo "${C_R}ERROR:${C_0} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ejecuta como root:  su -  y luego  bash $0"
id "$TARGET_USER" >/dev/null 2>&1 || die "El usuario '$TARGET_USER' no existe."
exec > >(tee -a "$LOG") 2>&1

HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
USER_GRP="$(id -gn "$TARGET_USER")"
BK="/root/backup-permisos-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"
FAILED=()
bk() { [ -e "$1" ] && cp -a --parents "$1" "$BK" 2>/dev/null; return 0; }
svc() {  # svc nombre  -> habilita e inicia (sysvinit)
  if [ -x "/etc/init.d/$1" ]; then
    update-rc.d "$1" defaults >/dev/null 2>&1
    service "$1" start >/dev/null 2>&1; ok "servicio $1"
  fi
}
inst() {
  local p
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 && continue
    apt-get install -y --no-install-recommends "$p" >>"$LOG" 2>&1 \
      && ok "instalado $p" || { warn "no se pudo instalar $p"; FAILED+=("$p"); }
  done
}

info "Usuario: $TARGET_USER  (home: $HOME_DIR)"

# ---------------------------------------------------------------- 1. Paquetes
info "1/9  Paquetes necesarios para permisos y automontaje"
apt-get update >>"$LOG" 2>&1
inst dbus dbus-x11 elogind libpam-elogind polkitd pkexec udisks2 udiskie \
     gvfs gvfs-backends gvfs-fuse dosfstools e2fsprogs eject parted ntfs-3g \
     exfatprogs network-manager network-manager-gnome rtkit rfkill acl \
     bluez blueman brightnessctl lxpolkit
# Nombre antiguo de polkit (Debian 12 y anteriores)
dpkg -s polkitd >/dev/null 2>&1 || inst policykit-1

# ---------------------------------------------------------------- 2. Grupos
info "2/9  Grupos del usuario"
for g in sudo audio video render netdev plugdev bluetooth lp cdrom; do
  if getent group "$g" >/dev/null; then
    id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$g" || { usermod -aG "$g" "$TARGET_USER"; ok "agregado a $g"; }
  fi
done

# ---------------------------------------------------------------- 3. PAM + elogind
info "3/9  Sesion elogind (necesaria para USB, red y audio)"
if ! grep -rqs 'pam_elogind' /etc/pam.d/common-session; then
  bk /etc/pam.d/common-session
  pam-auth-update --enable elogind >>"$LOG" 2>&1
  grep -rqs 'pam_elogind' /etc/pam.d/common-session || \
    echo 'session optional pam_elogind.so' >> /etc/pam.d/common-session
  ok "pam_elogind habilitado"
else
  ok "pam_elogind ya estaba habilitado"
fi
svc dbus
svc elogind

# Modo de emergencia: Xorg mediante wrapper (solo si lo pides)
if [ "$XWRAPPER" = yes ]; then
  inst xserver-xorg-legacy
  bk /etc/X11/Xwrapper.config
  printf 'allowed_users=console\nneeds_root_rights=yes\n' > /etc/X11/Xwrapper.config
  chmod 644 /etc/X11/Xwrapper.config
  ok "Xwrapper configurado (X corre con permisos elevados)"
fi

# ---------------------------------------------------------------- 4. Polkit
info "4/9  Reglas de polkit (red, USB, apagado)"
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/50-local-usuario.rules <<'EOF'
// Reglas locales (antiX Core + bspwm).
// Evitan los "no tienes permiso" cuando no hay sesion activa registrada.

// Red: usuarios del grupo netdev pueden gestionar NetworkManager
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("netdev") &&
        action.id.indexOf("org.freedesktop.NetworkManager.") === 0) {
        return polkit.Result.YES;
    }
});

// Discos extraibles: grupo plugdev puede montar, desmontar y expulsar
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("plugdev") &&
        action.id.match(/^org\.freedesktop\.udisks2\.(filesystem-mount|filesystem-mount-other-seat|filesystem-unmount-others|encrypted-unlock|eject-media|power-off-drive|loop-setup)$/)) {
        return polkit.Result.YES;
    }
});

// Apagar / reiniciar / suspender: grupo sudo
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("sudo") &&
        action.id.match(/^org\.freedesktop\.login1\.(power-off|reboot|suspend|hibernate)/)) {
        return polkit.Result.YES;
    }
});
EOF
chmod 644 /etc/polkit-1/rules.d/50-local-usuario.rules
ok "reglas polkit instaladas"

# Agente de polkit para ventanas de contrasena (lxpolkit o polkit-gnome)
if ! command -v lxpolkit >/dev/null 2>&1; then
  inst policykit-1-gnome
  AGENT="$(dpkg -L policykit-1-gnome 2>/dev/null | grep 'authentication-agent-1$' | head -1)"
  if [ -n "$AGENT" ] && [ -f "$HOME_DIR/.config/bspwm/bspwmrc" ]; then
    sed -i "s|^run lxpolkit|run $AGENT|" "$HOME_DIR/.config/bspwm/bspwmrc"
    ok "agente polkit-gnome configurado"
  fi
fi

# ---------------------------------------------------------------- 5. Permisos de archivos de /etc
info "5/9  Normalizando permisos de archivos de configuracion"
for f in /etc/X11/xorg.conf.d/*.conf /etc/sysctl.d/99-t61-*.conf \
         /etc/modprobe.d/t61-*.conf /etc/security/limits.d/10-nocore.conf \
         /etc/NetworkManager/conf.d/*.conf /etc/tlp.d/*.conf \
         /etc/apt/apt.conf.d/20auto-upgrades /etc/ssh/sshd_config.d/99-hardening.conf \
         /etc/fstab /etc/network/interfaces /etc/default/keyboard; do
  [ -f "$f" ] && chmod 644 "$f" && chown root:root "$f"
done
chmod 755 /etc/X11/xorg.conf.d /etc/NetworkManager/conf.d 2>/dev/null
chmod 755 /usr/local/bin/perfmode /usr/local/sbin/perfmode-set 2>/dev/null

# UMASK 027 (del endurecimiento) rompe archivos compartidos con servicios.
# Se vuelve a 022; tu carpeta personal sigue siendo privada (750).
if grep -qE '^UMASK\s+027' /etc/login.defs; then
  bk /etc/login.defs
  sed -i -E 's/^UMASK\s+.*/UMASK           022/' /etc/login.defs
  ok "UMASK restaurado a 022"
fi

# sudoers para el selector de perfil de CPU (con el usuario correcto)
if [ -x /usr/local/sbin/perfmode-set ]; then
  echo "$TARGET_USER ALL=(root) NOPASSWD: /usr/local/sbin/perfmode-set" > /etc/sudoers.d/perfmode
  chmod 440 /etc/sudoers.d/perfmode
  visudo -cf /etc/sudoers.d/perfmode >/dev/null || { rm -f /etc/sudoers.d/perfmode; warn "sudoers invalido, eliminado"; }
fi

# ---------------------------------------------------------------- 6. Carpeta personal
info "6/9  Propiedad y permisos de tu carpeta personal"
chown "$TARGET_USER:$USER_GRP" "$HOME_DIR"
chmod 750 "$HOME_DIR"
n=$(find "$HOME_DIR" -xdev ! -user "$TARGET_USER" 2>/dev/null | wc -l)
if [ "$n" -gt 0 ]; then
  find "$HOME_DIR" -xdev ! -user "$TARGET_USER" -exec chown -h "$TARGET_USER:$USER_GRP" {} + 2>/dev/null
  ok "corregidos $n archivos que no eran tuyos"
fi
for d in "$HOME_DIR/.config" "$HOME_DIR/.local" "$HOME_DIR/.cache"; do
  [ -d "$d" ] && chown -R "$TARGET_USER:$USER_GRP" "$d"
done
chmod 755 "$HOME_DIR/.xinitrc" "$HOME_DIR/.config/bspwm/bspwmrc" "$HOME_DIR"/.config/polybar/launch.sh \
          "$HOME_DIR"/.config/polybar/scripts/*.sh "$HOME_DIR"/.local/bin/* 2>/dev/null

# .xinitrc con respaldo por si XDG_RUNTIME_DIR no existe (audio/pipewire lo necesitan)
[ -f "$HOME_DIR/.xinitrc" ] && cp -a "$HOME_DIR/.xinitrc" "$BK/xinitrc.bak"
cat > "$HOME_DIR/.xinitrc" <<'EOF'
#!/bin/sh
[ -f "$HOME/.Xresources" ] && xrdb -merge "$HOME/.Xresources"
export XDG_CURRENT_DESKTOP=bspwm
export mesa_glthread=true
# Respaldo: si elogind no creo XDG_RUNTIME_DIR, lo creamos nosotros
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
  mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
fi
exec dbus-launch --exit-with-session bspwm
EOF
chown "$TARGET_USER:$USER_GRP" "$HOME_DIR/.xinitrc"; chmod 755 "$HOME_DIR/.xinitrc"

# ---------------------------------------------------------------- 7. udev
info "7/9  Reglas udev (rfkill, brillo, dispositivos)"
cat > /etc/udev/rules.d/70-local-permisos.rules <<'EOF'
# Bluetooth/WiFi: permitir rfkill al grupo netdev
KERNEL=="rfkill", SUBSYSTEM=="misc", GROUP="netdev", MODE="0660"
# Brillo de pantalla: grupo video
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
ACTION=="add", SUBSYSTEM=="leds", KERNEL=="*::kbd_backlight", RUN+="/bin/chgrp video /sys/class/leds/%k/brightness", RUN+="/bin/chmod g+w /sys/class/leds/%k/brightness"
EOF
chmod 644 /etc/udev/rules.d/70-local-permisos.rules
udevadm control --reload-rules 2>/dev/null
udevadm trigger 2>/dev/null
rfkill unblock all 2>/dev/null

# ---------------------------------------------------------------- 8. NetworkManager
info "8/9  NetworkManager"
if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
  bk /etc/NetworkManager/NetworkManager.conf
  if grep -q 'managed=false' /etc/NetworkManager/NetworkManager.conf; then
    sed -i 's/managed=false/managed=true/' /etc/NetworkManager/NetworkManager.conf
    ok "NetworkManager administrara las interfaces (managed=true)"
  fi
fi
# Interfaces definidas en ifupdown chocan con NM
if [ -f /etc/network/interfaces ] && grep -Eq '^\s*(auto|allow-hotplug|iface)\s+(eth|en|wl)' /etc/network/interfaces; then
  bk /etc/network/interfaces
  awk '/^[[:space:]]*(auto|allow-hotplug|iface|wpa-|wireless-)/ && $0 !~ /[[:space:]]lo([[:space:]]|$)/ {print "#" $0; next} {print}' \
     /etc/network/interfaces > /tmp/interfaces.new && install -m 644 /tmp/interfaces.new /etc/network/interfaces
  rm -f /tmp/interfaces.new
  ok "interfaces de /etc/network/interfaces comentadas"
fi
dpkg -s connman >/dev/null 2>&1 && warn "connman esta instalado y compite con NetworkManager (quitalo: apt purge connman)"
svc network-manager
svc bluetooth
service dbus reload >/dev/null 2>&1
nmcli networking on >/dev/null 2>&1
nmcli radio wifi on >/dev/null 2>&1

# ---------------------------------------------------------------- 9. Diagnostico
info "9/9  Diagnostico"
echo "--- Grupos de $TARGET_USER:"; id -nG "$TARGET_USER"
echo "--- Procesos clave:"
for p in dbus-daemon elogind polkitd NetworkManager bluetoothd udisksd; do
  pgrep -x "$p" >/dev/null && echo "  [ok]  $p" || echo "  [NO]  $p"
done
echo "--- PAM elogind:"; grep -rs pam_elogind /etc/pam.d/common-session || echo "  (no encontrado)"
echo "--- Sesiones:"; loginctl list-sessions 2>/dev/null || echo "  loginctl no disponible"
echo "--- NetworkManager:"; nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | head
echo "--- Denegaciones AppArmor recientes:"
dmesg 2>/dev/null | grep -i 'apparmor="DENIED"' | tail -n 5 || true

echo
echo "${C_G}========================  LISTO  ========================${C_0}"
[ "${#FAILED[@]}" -gt 0 ] && warn "No se instalaron: ${FAILED[*]}"
echo "IMPORTANTE: los cambios de grupos y de sesion requieren REINICIAR:"
echo "    reboot"
echo "Despues entra por la TTY1 con '$TARGET_USER' y prueba:"
echo "    loginctl show-session \$(loginctl | awk '/$TARGET_USER/{print \$1; exit}') -p Active   (debe decir Active=yes)"
echo "    udisksctl status            # discos detectados"
echo "    nmcli device                # estado de la red"
echo "Si X no inicia tras reiniciar:  bash fix-permisos.sh $TARGET_USER --xwrapper"
echo "Backups: $BK    Log: $LOG"
