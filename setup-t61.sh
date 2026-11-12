#!/usr/bin/env bash
# =============================================================================
#  setup-t61.sh  -  antiX Core + bspwm + polybar para ThinkPad T61
#  (Core 2 Duo, Intel GMA X3100 / GM965, 64 bits)
#
#  Uso (como root, con internet por cable, en una TTY):
#      bash setup-t61.sh NOMBRE_DE_TU_USUARIO
#
#  Opciones por variable de entorno:
#      INSTALL_FIREFOX=yes|no       (por defecto yes)
#      INSTALL_LIBREOFFICE=yes|no   (por defecto no, es pesado para este equipo)
#      KB_LAYOUT=latam              (distribucion de teclado)
#
#  Es re-ejecutable (idempotente en lo posible). Log: /var/log/t61-setup.log
# =============================================================================
set -u
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

LOG=/var/log/t61-setup.log
INSTALL_FIREFOX="${INSTALL_FIREFOX:-yes}"
INSTALL_LIBREOFFICE="${INSTALL_LIBREOFFICE:-no}"
KB_LAYOUT="${KB_LAYOUT:-latam}"
BK="/root/backup-t61-$(date +%Y%m%d-%H%M%S)"
FAILED=()

C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_R=$'\e[1;31m'; C_B=$'\e[1;34m'; C_0=$'\e[0m'
info() { echo "${C_B}==>${C_0} $*"; }
ok()   { echo "${C_G} ok${C_0} $*"; }
warn() { echo "${C_Y} !!${C_0} $*"; }
die()  { echo "${C_R}ERROR:${C_0} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ejecuta como root:  su -  y luego  bash $0 usuario"
command -v apt-get >/dev/null || die "Este script es para antiX/Debian (apt)."

exec > >(tee -a "$LOG") 2>&1

# ---------------------------------------------------------------- usuario ----
TARGET_USER="${1:-${SUDO_USER:-}}"
[ -z "$TARGET_USER" ] && TARGET_USER="$(getent passwd 1000 | cut -d: -f1)"
[ -n "$TARGET_USER" ] && id "$TARGET_USER" >/dev/null 2>&1 \
  || die "No encuentro el usuario. Uso: bash $0 NOMBRE_USUARIO"
[ "$TARGET_USER" = "root" ] && die "Usa un usuario normal, no root."
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
USER_GRP="$(id -gn "$TARGET_USER")"
info "Usuario objetivo: $TARGET_USER ($HOME_DIR)"
mkdir -p "$BK"

# ---------------------------------------------------------------- helpers ----
bk() { [ -e "$1" ] && cp -a --parents "$1" "$BK" 2>/dev/null; return 0; }

inst() {
  local p
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 && continue
    if apt-get install -y --no-install-recommends "$p" >>"$LOG" 2>&1; then
      ok "$p"
    else
      warn "no se pudo instalar: $p"; FAILED+=("$p")
    fi
  done
}

enable_svc() {   # sysvinit (por defecto en antiX). Con runit, hazlo a mano.
  local s="$1"
  if [ -x "/etc/init.d/$s" ] && command -v update-rc.d >/dev/null; then
    update-rc.d "$s" defaults >/dev/null 2>&1
    service "$s" start >/dev/null 2>&1 || true
    ok "servicio $s habilitado"
  else
    warn "servicio $s: no encontrado en /etc/init.d (¿runit?). Habilitalo manualmente."
  fi
}

# ============================================================================
# 1. APT: repos, actualizacion
# ============================================================================
info "1/10  Repositorios y actualizacion"
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
  [ -f "$f" ] || continue
  grep -qE '^deb .*debian' "$f" || continue
  grep -q 'non-free-firmware' "$f" && continue
  bk "$f"
  sed -i -E '/^deb .*debian/ s/ main( |$)/ main contrib non-free non-free-firmware\1/' "$f"
  ok "non-free-firmware habilitado en $f"
done
apt-get update >>"$LOG" 2>&1 || warn "apt-get update fallo (¿hay internet?)"
apt-get -y upgrade >>"$LOG" 2>&1 || warn "upgrade con avisos, revisa $LOG"

# ============================================================================
# 2. Paquetes
# ============================================================================
info "2/10  Instalando paquetes (puede tardar)"

# --- X11 + driver Intel + sesion
inst xserver-xorg-core xserver-xorg-video-intel xserver-xorg-input-libinput \
     xinit x11-xserver-utils x11-xkb-utils x11-utils xauth xdg-utils xdg-user-dirs \
     dbus dbus-x11 elogind libpam-elogind rtkit
# --- graficos / video (GMA X3100: aceleracion 2D + Mesa; VA-API solo MPEG-2)
inst mesa-utils libgl1-mesa-dri libglx-mesa0 mesa-va-drivers i965-va-driver vainfo
# --- gestor de ventanas y panel
inst bspwm sxhkd polybar dunst libnotify-bin rxvt-unicode dmenu slock xss-lock \
     feh scrot brightnessctl arandr fonts-font-awesome fonts-dejavu-core \
     adwaita-icon-theme
# --- polkit (el nombre cambia segun version de Debian)
inst polkitd pkexec policykit-1 lxpolkit
# --- red
inst network-manager network-manager-gnome wpasupplicant wireless-tools iw rfkill \
     firmware-iwlwifi firmware-atheros
# --- audio + bluetooth
inst pipewire pipewire-pulse pipewire-alsa wireplumber libspa-0.2-bluetooth \
     alsa-utils pulseaudio-utils pavucontrol bluez blueman
# --- energia / sensores
inst tlp acpi acpid lm-sensors powertop
inst intel-microcode iucode-tool
# --- archivos y USB
inst pcmanfm gvfs udisks2 udiskie ntfs-3g exfatprogs zip unzip p7zip-full
# --- multimedia
inst mpv yt-dlp streamlink ffmpeg cmus
# --- ofimatica ligera
inst zathura zathura-pdf-poppler abiword gnumeric
[ "$INSTALL_LIBREOFFICE" = "yes" ] && inst libreoffice-writer libreoffice-calc libreoffice-impress
# --- navegador
[ "$INSTALL_FIREFOX" = "yes" ] && inst firefox-esr
# --- programacion ligera
inst geany vim git build-essential python3 python3-pip python3-venv gdb jq \
     ripgrep tmux htop curl wget
# --- seguridad
inst ufw apparmor apparmor-utils apparmor-profiles libpam-pwquality \
     unattended-upgrades cron debsums lynis

# ============================================================================
# 3. Usuario y grupos
# ============================================================================
info "3/10  Grupos del usuario"
for g in sudo audio video netdev plugdev bluetooth lp cdrom; do
  getent group "$g" >/dev/null && usermod -aG "$g" "$TARGET_USER" && ok "grupo $g"
done

# ============================================================================
# 4. Seguridad
# ============================================================================
info "4/10  Endureciendo el sistema"

# 4.1 sysctl
cat > /etc/sysctl.d/99-t61-hardening.conf <<'EOF'
# --- Kernel
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.randomize_va_space = 2
kernel.sysrq = 176
kernel.kexec_load_disabled = 1
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1
kernel.perf_event_paranoid = 3
net.core.bpf_jit_harden = 2
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
# (no se desactivan los user namespaces: Firefox los necesita para su sandbox)
# --- Red
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.all.use_tempaddr = 2
net.ipv6.conf.default.use_tempaddr = 2
EOF

# 4.2 sysctl de rendimiento / ahorro
cat > /etc/sysctl.d/99-t61-perf.conf <<'EOF'
vm.swappiness = 20
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
kernel.nmi_watchdog = 0
EOF
sysctl --system >/dev/null 2>&1 && ok "sysctl aplicado"

# 4.3 modulos de kernel innecesarios / de riesgo
cat > /etc/modprobe.d/t61-hardening.conf <<'EOF'
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
install firewire-core /bin/false
install firewire-ohci /bin/false
EOF

# 4.4 sin core dumps
cat > /etc/security/limits.d/10-nocore.conf <<'EOF'
* hard core 0
EOF

# 4.5 umask y permisos
bk /etc/login.defs
sed -i -E 's/^UMASK\s+.*/UMASK           027/' /etc/login.defs
grep -q '^HOME_MODE' /etc/login.defs || echo 'HOME_MODE      0750' >> /etc/login.defs
chmod 700 /root
chmod 750 "$HOME_DIR"

# 4.6 "su" solo para el grupo sudo
if ! grep -Eq '^\s*auth\s+required\s+pam_wheel' /etc/pam.d/su; then
  bk /etc/pam.d/su
  sed -i '/^auth.*sufficient.*pam_rootok.so/a auth       required   pam_wheel.so group=sudo' /etc/pam.d/su
fi

# 4.7 firewall: todo entrante denegado
ufw --force reset >/dev/null 2>&1
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw logging low >/dev/null
ufw --force enable >/dev/null && ok "ufw activo (entrante denegado)"
enable_svc ufw

# 4.8 AppArmor, cron y parches automaticos
enable_svc apparmor
enable_svc cron
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# 4.9 servicios que no necesitas
for s in avahi-daemon cups cups-browsed exim4 rpcbind nfs-common saned; do
  if [ -x "/etc/init.d/$s" ]; then
    service "$s" stop >/dev/null 2>&1
    update-rc.d "$s" disable >/dev/null 2>&1
    ok "servicio $s deshabilitado"
  fi
done

# 4.10 SSH (solo si ya esta instalado)
if [ -d /etc/ssh/sshd_config.d ]; then
  cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PermitRootLogin no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
EOF
  ok "sshd endurecido (el puerto sigue cerrado en ufw; abre con: ufw limit 22/tcp)"
fi

# 4.11 /tmp y /dev/shm
bk /etc/fstab
grep -Eq '^\S+\s+/tmp\s' /etc/fstab || \
  echo 'tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,mode=1777,size=512M 0 0' >> /etc/fstab
grep -Eq '^\S+\s+/dev/shm\s' /etc/fstab || \
  echo 'tmpfs /dev/shm tmpfs defaults,nosuid,nodev 0 0' >> /etc/fstab

# 4.12 parametros de arranque
if [ -f /etc/default/grub ]; then
  bk /etc/default/grub
  for p in apparmor=1 security=apparmor slab_nomerge page_alloc.shuffle=1 \
           randomize_kstack_offset=on zswap.enabled=1; do
    key="${p%%=*}"
    grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | grep -q "$key" || \
      sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"|\1 $p\"|" /etc/default/grub
  done
  grep -q 'apparmor=1' /etc/default/grub || warn "No pude editar GRUB_CMDLINE_LINUX_DEFAULT; agrega 'apparmor=1 security=apparmor' a mano."
  command -v update-grub >/dev/null && update-grub >>"$LOG" 2>&1 && ok "GRUB actualizado"
else
  warn "No hay /etc/default/grub (¿otro bootloader?). Agrega a mano: apparmor=1 security=apparmor zswap.enabled=1"
fi

# ============================================================================
# 5. Rendimiento y energia
# ============================================================================
info "5/10  Rendimiento y energia"

# 5.1 noatime en la raiz
if awk '$1 !~ /^#/ && $2=="/" && $3 ~ /^(ext4|xfs|btrfs|f2fs)$/ && $4 !~ /noatime/ {f=1} END{exit !f}' /etc/fstab; then
  awk '$1 !~ /^#/ && $2=="/" && $3 ~ /^(ext4|xfs|btrfs|f2fs)$/ && $4 !~ /noatime/ {$4=$4",noatime"} {print}' \
      /etc/fstab > /tmp/fstab.new
  if [ -s /tmp/fstab.new ] && [ "$(wc -l < /tmp/fstab.new)" -ge "$(wc -l < /etc/fstab)" ]; then
    install -m 644 /tmp/fstab.new /etc/fstab && ok "noatime en /"
  fi
  rm -f /tmp/fstab.new
fi

# 5.2 TRIM semanal si el disco es SSD
if lsblk -dno ROTA 2>/dev/null | grep -q '^0'; then
  printf '#!/bin/sh\nfstrim -av\n' > /etc/cron.weekly/fstrim && chmod +x /etc/cron.weekly/fstrim
  ok "fstrim semanal (SSD detectado)"
fi

# 5.3 TLP
mkdir -p /etc/tlp.d
cat > /etc/tlp.d/10-t61.conf <<'EOF'
TLP_ENABLE=1
CPU_SCALING_GOVERNOR_ON_AC=ondemand
CPU_SCALING_GOVERNOR_ON_BAT=conservative
DISK_APM_LEVEL_ON_AC="254 254"
DISK_APM_LEVEL_ON_BAT="128 128"
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on
SOUND_POWER_SAVE_ON_BAT=1
RUNTIME_PM_ON_BAT=auto
EOF
enable_svc tlp
enable_svc acpid

# 5.4 selector de perfil de CPU (ahorro / auto / max) desde el panel
cat > /usr/local/sbin/perfmode-set <<'EOF'
#!/bin/sh
# Cambia el governor de CPU. Solo acepta valores conocidos.
case "$1" in
  powersave|conservative|ondemand|performance) ;;
  *) echo "uso: perfmode-set powersave|conservative|ondemand|performance"; exit 1 ;;
esac
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo "$1" > "$f" 2>/dev/null
done
EOF
chown root:root /usr/local/sbin/perfmode-set && chmod 755 /usr/local/sbin/perfmode-set

cat > /usr/local/bin/perfmode <<'EOF'
#!/bin/bash
# perfmode status | next   (ahorro -> auto -> max -> ahorro ...)
G=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
F=/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
cur=$(cat "$G" 2>/dev/null)
case "$1" in
  next)
    case "$cur" in
      powersave)               n=ondemand ;;
      ondemand|conservative)   n=performance ;;
      *)                       n=powersave ;;
    esac
    sudo -n /usr/local/sbin/perfmode-set "$n"
    notify-send -t 1500 "Perfil de CPU" "$n" 2>/dev/null
    ;;
  *)
    case "$cur" in
      powersave)    lbl=eco ;;
      conservative) lbl=bat ;;
      ondemand)     lbl=auto ;;
      performance)  lbl=max ;;
      *)            lbl=${cur:-n/a} ;;
    esac
    mhz=$(( $(cat "$F" 2>/dev/null || echo 0) / 1000 ))
    printf '\xef\x83\xa4 %s %sMHz' "$lbl" "$mhz"
    ;;
esac
EOF
chmod 755 /usr/local/bin/perfmode

echo "$TARGET_USER ALL=(root) NOPASSWD: /usr/local/sbin/perfmode-set" > /etc/sudoers.d/perfmode
chmod 440 /etc/sudoers.d/perfmode
visudo -cf /etc/sudoers.d/perfmode >/dev/null || { rm -f /etc/sudoers.d/perfmode; warn "sudoers invalido, eliminado"; }

# ============================================================================
# 6. Graficos Intel GMA X3100, teclado, TrackPoint
# ============================================================================
info "6/10  Xorg: graficos Intel, teclado, TrackPoint"
mkdir -p /etc/X11/xorg.conf.d

# UXA es el metodo de aceleracion mas estable en esta generacion (gen4).
# Si tienes problemas, borra este archivo y Xorg usara el driver 'modesetting'.
cat > /etc/X11/xorg.conf.d/20-intel.conf <<'EOF'
Section "Device"
    Identifier "Intel GMA X3100"
    Driver     "intel"
    Option     "AccelMethod" "uxa"
EndSection
EOF

cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
    Identifier "teclado"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$KB_LAYOUT"
EndSection
EOF

cat > /etc/X11/xorg.conf.d/40-trackpoint.conf <<'EOF'
Section "InputClass"
    Identifier "TrackPoint T61"
    MatchProduct "TrackPoint"
    MatchIsPointer "on"
    Driver "libinput"
    Option "ScrollMethod" "button"
    Option "ScrollButton" "2"
    Option "AccelSpeed" "0.3"
EndSection
EOF

# ============================================================================
# 7. Red: NetworkManager
# ============================================================================
info "7/10  NetworkManager"
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-privacy.conf <<'EOF'
[device-mac-randomization]
wifi.scan-rand-mac-address=yes
[connection-mac-randomization]
ethernet.cloned-mac-address=stable
wifi.cloned-mac-address=stable
EOF
dpkg -s connman >/dev/null 2>&1 && warn "connman esta instalado y puede chocar con NetworkManager."

# ============================================================================
# 8. Configuracion del usuario (bspwm, sxhkd, polybar, mpv, etc.)
# ============================================================================
info "8/10  Configuracion de bspwm / sxhkd / polybar"
CFG_DIR="$HOME_DIR/.config"
mkdir -p "$CFG_DIR"/{bspwm,sxhkd,polybar/scripts,mpv,gtk-3.0} "$HOME_DIR/.local/bin"

# ---- iconos Font Awesome 4.7 (bytes UTF-8)
I_TERM=$'\xef\x84\xa0'; I_WEB=$'\xef\x82\xac'; I_CODE=$'\xef\x84\xa1'
I_DOC=$'\xef\x85\x9c';  I_MEDIA=$'\xef\x80\x81'
I_CAL=$'\xef\x81\xb3';  I_CPU=$'\xef\x8b\x9b'; I_MEM=$'\xef\x87\x80'
I_VIDEO=$'\xef\x84\x88'; I_PLUG=$'\xef\x87\xa6'
I_B0=$'\xef\x89\x84'; I_B1=$'\xef\x89\x83'; I_B2=$'\xef\x89\x82'
I_B3=$'\xef\x89\x81'; I_B4=$'\xef\x89\x80'

BAT="$(ls /sys/class/power_supply 2>/dev/null | grep -E '^BAT' | head -1)"; BAT="${BAT:-BAT0}"
ADP="$(ls /sys/class/power_supply 2>/dev/null | grep -E '^(AC|ADP)' | head -1)"; ADP="${ADP:-AC}"

# ---- bspwmrc
cat > "$CFG_DIR/bspwm/bspwmrc" <<EOF
#!/bin/sh
export PATH="\$HOME/.local/bin:\$PATH"
run() { pgrep -x "\$1" >/dev/null 2>&1 || "\$@" & }

setxkbmap $KB_LAYOUT
xsetroot -cursor_name left_ptr -solid '#1d1f21'
[ -f "\$HOME/.wallpaper" ] && feh --no-fehbg --bg-fill "\$HOME/.wallpaper"
xset r rate 300 40
xset s 300 300          # bloquea tras 5 min de inactividad
xset dpms 0 0 600       # apaga pantalla a los 10 min

# ---- 5 escritorios
bspc monitor -d 1 2 3 4 5

bspc config border_width         2
bspc config window_gap           6
bspc config split_ratio          0.52
bspc config borderless_monocle   true
bspc config gapless_monocle      true
bspc config focus_follows_pointer true
bspc config normal_border_color  '#373b41'
bspc config focused_border_color '#81a2be'

bspc rule -a Pavucontrol          state=floating
bspc rule -a Arandr               state=floating
bspc rule -a Blueman-manager      state=floating
bspc rule -a Nm-connection-editor state=floating

# ---- autostart
run sxhkd
"\$HOME/.config/polybar/launch.sh" &
run dunst
run lxpolkit
run pipewire
( sleep 1; run wireplumber; run pipewire-pulse ) &
run nm-applet
run blueman-applet
run udiskie --tray
pgrep -x xss-lock >/dev/null || xss-lock -- slock &
EOF
chmod 755 "$CFG_DIR/bspwm/bspwmrc"

# ---- sxhkdrc
cat > "$CFG_DIR/sxhkd/sxhkdrc" <<'EOF'
# ===== Atajos (super = tecla Windows) =====
super + Return
    urxvt
super + d
    dmenu_run
super + w
    firefox-esr
super + e
    pcmanfm
super + shift + x
    slock

# cerrar / salir / recargar
super + q
    bspc node -c
super + alt + r
    bspc wm -r
super + alt + q
    bspc quit
super + Escape
    pkill -USR1 -x sxhkd

# escritorios 1-5
super + {1-5}
    bspc desktop -f '^{1-5}'
super + shift + {1-5}
    bspc node -d '^{1-5}'
super + Tab
    bspc desktop -f last

# ventanas
super + {h,j,k,l}
    bspc node -f {west,south,north,east}
super + shift + {h,j,k,l}
    bspc node -s {west,south,north,east}
super + f
    bspc node -t ~fullscreen
super + t
    bspc node -t ~floating
super + m
    bspc desktop -l next
super + ctrl + {h,j,k,l}
    bspc node -z {left -20 0,bottom 0 20,top 0 -20,right 20 0}

# teclas multimedia del ThinkPad
XF86AudioRaiseVolume
    ~/.config/polybar/scripts/audio.sh up
XF86AudioLowerVolume
    ~/.config/polybar/scripts/audio.sh down
XF86AudioMute
    ~/.config/polybar/scripts/audio.sh mute
XF86MonBrightnessUp
    brightnessctl set +10%
XF86MonBrightnessDown
    brightnessctl set 10%-

Print
    scrot ~/captura_%Y%m%d_%H%M%S.png
EOF

# ---- scripts del panel
cat > "$CFG_DIR/polybar/launch.sh" <<'EOF'
#!/bin/sh
killall -q polybar
while pgrep -u "$(id -u)" -x polybar >/dev/null; do sleep 0.2; done
polybar main >>/tmp/polybar.log 2>&1 &
EOF

cat > "$CFG_DIR/polybar/scripts/net.sh" <<'EOF'
#!/bin/bash
line=$(nmcli -t -f TYPE,STATE,CONNECTION device 2>/dev/null | grep ':connected' | grep -Ev '^(loopback|bridge|bluetooth|tun)' | head -1)
type=${line%%:*}
name=${line#*:connected:}
case "$type" in
  wifi)     printf '\xef\x87\xab %s' "$name" ;;
  ethernet) printf '\xef\x83\xa8 %s' "$name" ;;
  *)        printf '\xef\x87\xab sin red' ;;
esac
EOF

cat > "$CFG_DIR/polybar/scripts/audio.sh" <<'EOF'
#!/bin/bash
S=@DEFAULT_AUDIO_SINK@
case "$1" in
  up)   wpctl set-volume -l 1.0 $S 5%+ ; exit ;;
  down) wpctl set-volume $S 5%- ; exit ;;
  mute) wpctl set-mute $S toggle ; exit ;;
esac
out=$(wpctl get-volume $S 2>/dev/null)
if [ -z "$out" ]; then printf '\xef\x80\xa6 --'; exit; fi
vol=$(echo "$out" | awk '{printf "%d", $2*100}')
if echo "$out" | grep -q MUTED; then printf '\xef\x80\xa6 mute'
else printf '\xef\x80\xa8 %s%%' "$vol"; fi
EOF

cat > "$CFG_DIR/polybar/scripts/bt.sh" <<'EOF'
#!/bin/bash
command -v bluetoothctl >/dev/null || { printf '\xef\x8a\x93 n/a'; exit; }
powered=$(bluetoothctl show 2>/dev/null | awk '/Powered:/{print $2}')
case "$1" in
  toggle)
    if [ "$powered" = yes ]; then bluetoothctl power off
    else rfkill unblock bluetooth; bluetoothctl power on; fi
    exit ;;
esac
if [ "$powered" != yes ]; then printf '\xef\x8a\x93 off'
else
  n=$(bluetoothctl devices Connected 2>/dev/null | wc -l)
  printf '\xef\x8a\x93 %s' "$n"
fi
EOF

cat > "$CFG_DIR/polybar/scripts/video.sh" <<'EOF'
#!/bin/bash
case "$1" in
  up)   brightnessctl -q set +5% ; exit ;;
  down) brightnessctl -q set 5%- ; exit ;;
esac
b=$(brightnessctl -m 2>/dev/null | cut -d, -f4)
printf '\xef\x84\x88 %s' "${b:---}"
EOF
chmod 755 "$CFG_DIR"/polybar/launch.sh "$CFG_DIR"/polybar/scripts/*.sh

# ---- polybar config.ini
CFG="$CFG_DIR/polybar/config.ini"
cat > "$CFG" <<'EOF'
[colors]
bg     = #1d1f21
fg     = #c5c8c6
dim    = #707880
accent = #81a2be
alert  = #cc6666

[bar/main]
width = 100%
height = 24
fixed-center = true
background = ${colors.bg}
foreground = ${colors.fg}
padding-left = 0
padding-right = 1
module-margin = 1
font-0 = DejaVu Sans Mono:size=9;2
font-1 = FontAwesome:size=10;2
modules-left = bspwm
modules-center = date
modules-right = perf cpu memory net audio bt video battery
enable-ipc = true

; ---------------- Escritorios (5) ----------------
[module/bspwm]
type = internal/bspwm
pin-workspaces = false
enable-click = true
enable-scroll = false
ws-icon-0 = 1;@I_TERM@
ws-icon-1 = 2;@I_WEB@
ws-icon-2 = 3;@I_CODE@
ws-icon-3 = 4;@I_DOC@
ws-icon-4 = 5;@I_MEDIA@
format = <label-state>
label-focused = %icon%
label-focused-foreground = ${colors.bg}
label-focused-background = ${colors.accent}
label-focused-padding = 2
label-occupied = %icon%
label-occupied-padding = 2
label-empty = %icon%
label-empty-foreground = ${colors.dim}
label-empty-padding = 2
label-urgent = %icon%
label-urgent-background = ${colors.alert}
label-urgent-padding = 2

; ---------------- Fecha ----------------
[module/date]
type = internal/date
interval = 30
date = %a %d %b
time = %H:%M
label = @I_CAL@ %date%  %time%

; ---------------- Bateria ----------------
[module/battery]
type = internal/battery
battery = @BAT@
adapter = @ADP@
full-at = 98
poll-interval = 10
format-charging = <label-charging>
label-charging = @I_PLUG@ %percentage%%
format-discharging = <ramp-capacity> <label-discharging>
label-discharging = %percentage%% %time%
format-full = <label-full>
label-full = @I_B0@ %percentage%%
ramp-capacity-0 = @I_B4@
ramp-capacity-0-foreground = ${colors.alert}
ramp-capacity-1 = @I_B3@
ramp-capacity-2 = @I_B2@
ramp-capacity-3 = @I_B1@
ramp-capacity-4 = @I_B0@

; ---------------- Rendimiento (clic = cambiar perfil CPU) ----------------
[module/perf]
type = custom/script
exec = /usr/local/bin/perfmode status
interval = 5
click-left = /usr/local/bin/perfmode next

[module/cpu]
type = internal/cpu
interval = 3
label = @I_CPU@ %percentage%%

[module/memory]
type = internal/memory
interval = 5
label = @I_MEM@ %percentage_used%%

; ---------------- Internet (clic = nmtui, clic der = editor) ----------------
[module/net]
type = custom/script
exec = @S@/net.sh
interval = 5
click-left = urxvt -e nmtui
click-right = nm-connection-editor

; ---------------- Audio (clic = pavucontrol, der = mute, rueda = volumen) ----------------
[module/audio]
type = custom/script
exec = @S@/audio.sh
interval = 2
click-left = pavucontrol
click-right = @S@/audio.sh mute
scroll-up = @S@/audio.sh up
scroll-down = @S@/audio.sh down

; ---------------- Bluetooth (clic = blueman, der = on/off) ----------------
[module/bt]
type = custom/script
exec = @S@/bt.sh
interval = 5
click-left = blueman-manager
click-right = @S@/bt.sh toggle

; ---------------- Video (clic = arandr, rueda = brillo) ----------------
[module/video]
type = custom/script
exec = @S@/video.sh
interval = 5
click-left = arandr
scroll-up = @S@/video.sh up
scroll-down = @S@/video.sh down
EOF

sub() { sed -i "s|@$1@|$2|g" "$CFG"; }
sub I_TERM "$I_TERM"; sub I_WEB "$I_WEB"; sub I_CODE "$I_CODE"
sub I_DOC "$I_DOC";   sub I_MEDIA "$I_MEDIA"; sub I_CAL "$I_CAL"
sub I_CPU "$I_CPU";   sub I_MEM "$I_MEM"; sub I_PLUG "$I_PLUG"
sub I_B0 "$I_B0"; sub I_B1 "$I_B1"; sub I_B2 "$I_B2"; sub I_B3 "$I_B3"; sub I_B4 "$I_B4"
sub BAT "$BAT"; sub ADP "$ADP"; sub S "$CFG_DIR/polybar/scripts"

# ---- bandeja del sistema (programas en segundo plano)
# polybar >= 3.7 usa modulo 'tray'; versiones anteriores usan tray-position.
PV="$(polybar --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [ -n "$PV" ] && [ "$(printf '%s\n3.7.0\n' "$PV" | sort -V | head -1)" = "3.7.0" ]; then
  sed -i 's/^modules-right = \(.*\)/modules-right = \1 tray/' "$CFG"
  cat >> "$CFG" <<'TRAYEOF'

; ---------------- Bandeja (apps en segundo plano) ----------------
[module/tray]
type = internal/tray
tray-spacing = 6px
tray-size = 14
tray-background = ${colors.bg}
TRAYEOF
else
  sed -i '/^\[bar\/main\]/a tray-position = right\ntray-padding = 4\ntray-background = ${colors.bg}' "$CFG"
fi
ok "polybar configurado (version ${PV:-desconocida}; log: /tmp/polybar.log)"

# ---- mpv: decodificacion por software optimizada (X3100 no decodifica H.264)
cat > "$CFG_DIR/mpv/mpv.conf" <<'EOF'
# Salida Xv: la mas ligera para este chip. Si falla, mpv cae a 'gpu'.
vo=xv,gpu
hwdec=no
vd-lavc-fast=yes
vd-lavc-skiploopfilter=nonref
vd-lavc-threads=2
framedrop=vo
cache=yes
demuxer-max-bytes=50MiB
demuxer-max-back-bytes=10MiB
audio-display=no
# Streaming: max 480p y solo H.264 (VP9/AV1 matan a un Core 2 Duo)
ytdl-format=bestvideo[height<=480][vcodec^=avc1]+bestaudio/best[height<=480]/worst
EOF

# ---- atajo para streams (Twitch, etc.): stream <url>
cat > "$HOME_DIR/.local/bin/stream" <<'EOF'
#!/bin/sh
# uso: stream https://twitch.tv/canal     (calidad baja, ideal para el T61)
exec streamlink --player mpv "$1" 480p,360p,worst
EOF
chmod 755 "$HOME_DIR/.local/bin/stream"

# ---- urxvt
cat > "$HOME_DIR/.Xresources" <<'EOF'
URxvt.font:            xft:DejaVu Sans Mono:size=10
URxvt.scrollBar:       false
URxvt.saveLines:       5000
URxvt.internalBorder:  6
URxvt.background:      #1d1f21
URxvt.foreground:      #c5c8c6
URxvt.cursorColor:     #81a2be
Xft.dpi:               96
Xft.antialias:         1
Xft.hinting:           1
Xft.hintstyle:         hintslight
EOF

# ---- GTK
cat > "$CFG_DIR/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-font-name=DejaVu Sans 9
gtk-icon-theme-name=Adwaita
gtk-enable-animations=false
EOF

# ---- xinitrc y arranque automatico de X en tty1
cat > "$HOME_DIR/.xinitrc" <<'EOF'
#!/bin/sh
[ -f "$HOME/.Xresources" ] && xrdb -merge "$HOME/.Xresources"
export XDG_CURRENT_DESKTOP=bspwm
export mesa_glthread=true
exec dbus-launch --exit-with-session bspwm
EOF
chmod 755 "$HOME_DIR/.xinitrc"

cat > "$HOME_DIR/.bash_profile" <<'EOF'
[ -f "$HOME/.profile" ] && . "$HOME/.profile"
[ -f "$HOME/.bashrc" ]  && . "$HOME/.bashrc"
export PATH="$HOME/.local/bin:$PATH"
# Inicia X automaticamente al entrar por la TTY1
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec startx
fi
EOF

chown -R "$TARGET_USER:$USER_GRP" "$CFG_DIR" "$HOME_DIR/.local" \
      "$HOME_DIR/.xinitrc" "$HOME_DIR/.Xresources" "$HOME_DIR/.bash_profile"
sudo -u "$TARGET_USER" xdg-user-dirs-update >/dev/null 2>&1 || true

# ============================================================================
# 9. Servicios
# ============================================================================
info "9/10  Servicios"
enable_svc dbus
enable_svc elogind
enable_svc bluetooth
rfkill unblock bluetooth >/dev/null 2>&1 || true

# ============================================================================
# 10. NetworkManager toma el control de la red (al final, para no cortar la descarga)
# ============================================================================
info "10/10  Entregando la red a NetworkManager"
if [ -f /etc/network/interfaces ] && grep -Eq '^\s*(auto|allow-hotplug|iface)\s+(eth|en|wl|wlan)' /etc/network/interfaces; then
  bk /etc/network/interfaces
  awk '/^[[:space:]]*(auto|allow-hotplug|iface|wpa-|wireless-)/ && $0 !~ / lo( |$)/ && $0 !~ /^[[:space:]]*(auto|allow-hotplug)[[:space:]]+lo/ {print "#" $0; next} {print}' \
      /etc/network/interfaces > /tmp/interfaces.new && install -m 644 /tmp/interfaces.new /etc/network/interfaces
  rm -f /tmp/interfaces.new
  ok "/etc/network/interfaces: interfaces comentadas (backup en $BK)"
fi
update-rc.d network-manager defaults >/dev/null 2>&1
# (no se reinicia la red ahora: se activa en el proximo arranque)

# ============================================================================
# Resumen
# ============================================================================
echo
echo "${C_G}============================  LISTO  ============================${C_0}"
if [ "${#FAILED[@]}" -gt 0 ]; then
  warn "Paquetes que no se instalaron: ${FAILED[*]}"
  warn "Busca su nombre en tu version de Debian:  apt-cache search <nombre>"
fi
echo "1) Reinicia:            reboot"
echo "2) Entra con tu usuario en la TTY1: X + bspwm arrancan solos."
echo "3) WiFi:                clic en el icono de red del panel (nmtui)."
echo "4) Auditoria de seguridad (cuando quieras):   sudo lynis audit system"
echo "5) Verifica graficos:   glxinfo -B | head   y   vainfo"
echo "Atajos: super+Enter terminal | super+d lanzador | super+1..5 escritorios"
echo "        super+w firefox | super+e archivos | super+shift+x bloquear"
echo "Backups en: $BK        Log: $LOG"
