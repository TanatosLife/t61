#!/usr/bin/env bash
# =============================================================================
#  personalizar-escritorio.sh
#  antiX Core + bspwm + polybar  (pensado para ThinkPad T61, sin compositor)
#
#  Instala y configura, de forma modular:
#    1. Bloqueo de pantalla + protector de pantalla (xsecurelock + reloj propio)
#    2. Gestor de sesion (bloquear / suspender / cerrar sesion / apagar / reiniciar)
#       con bloqueo garantizado al suspender y al reanudar
#    3. Temas claro y oscuro coherentes (panel, GTK, terminal, menus, avisos, bloqueo)
#    4. Panel reorganizado: reloj al centro, escritorios y boton de energia al final
#    5. Menu de energia desplegable (Apagar, Reiniciar, Suspender, Cerrar sesion)
#
#  Uso (como root):
#      bash personalizar-escritorio.sh [usuario] [--tema oscuro|claro]
#                                      [--solo mod1,mod2] [--sin-lid]
#
#  Modulos: paquetes temas bloqueo sesion energia panel integracion
#  Ejemplo: bash personalizar-escritorio.sh cronos --solo temas,panel
#
#  Es re-ejecutable. Hace copia de lo que modifica. Log: /var/log/personalizar-escritorio.log
# =============================================================================
set -u
umask 022
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

USUARIO="cronos"
TEMA_INICIAL="oscuro"
SOLO=""
LID=yes
MODULOS="paquetes temas bloqueo sesion energia panel integracion"
LOG=/var/log/personalizar-escritorio.log
FAILED=()

C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_R=$'\e[1;31m'; C_B=$'\e[1;34m'; C_0=$'\e[0m'
info() { echo "${C_B}==>${C_0} $*"; }
ok()   { echo "${C_G} ok${C_0} $*"; }
warn() { echo "${C_Y} !!${C_0} $*"; }
die()  { echo "${C_R}ERROR:${C_0} $*"; exit 1; }

uso() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tema)    TEMA_INICIAL="${2:-}"; shift ;;
    --solo)    SOLO="${2:-}"; shift ;;
    --sin-lid) LID=no ;;
    -h|--ayuda|--help) uso; exit 0 ;;
    -*) die "opcion desconocida: $1  (usa --ayuda)" ;;
    *)  USUARIO="$1" ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || die "Ejecuta como root:  su -  y luego  bash $0"
case "$TEMA_INICIAL" in claro|oscuro) ;; *) die "--tema debe ser 'claro' u 'oscuro'" ;; esac
id "$USUARIO" >/dev/null 2>&1 || die "El usuario '$USUARIO' no existe."
exec > >(tee -a "$LOG") 2>&1

HOME_DIR="$(getent passwd "$USUARIO" | cut -d: -f6)"
GRP="$(id -gn "$USUARIO")"
BASE="$HOME_DIR/.config/mi-escritorio"
BIN="$BASE/bin"
BK="/root/backup-escritorio-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK" "$BIN" "$BASE/temas" "$BASE/rofi" "$HOME_DIR/.local/bin"

bk() { [ -e "$1" ] && cp -a --parents "$1" "$BK" 2>/dev/null; return 0; }
quiere() { [ -z "$SOLO" ] && return 0; case ",$SOLO," in *",$1,"*) return 0 ;; esac; return 1; }
inst() {
  local p
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 && continue
    if apt-get install -y --no-install-recommends "$p" >>"$LOG" 2>&1; then ok "instalado $p"
    else warn "no se pudo instalar: $p"; FAILED+=("$p"); fi
  done
}
instala_script() {   # instala_script nombre  (lee stdin)  -> $BIN/nombre ejecutable
  cat > "$BIN/$1"; chmod 755 "$BIN/$1"; ok "script $1"
}

info "Usuario: $USUARIO ($HOME_DIR) | tema inicial: $TEMA_INICIAL"

# =============================================================================
# MODULO: paquetes
# =============================================================================
mod_paquetes() {
  info "[paquetes] Instalando dependencias minimas"
  apt-get update >>"$LOG" 2>&1 || warn "apt-get update fallo (¿hay internet?)"
  # bloqueo / sesion
  inst xsecurelock xss-lock x11-xserver-utils dbus-bin util-linux
  # menus, avisos, terminal
  inst rofi dunst libnotify-bin rxvt-unicode xsettingsd
  # temas GTK (Arc claro/oscuro) con respaldo Adwaita
  inst arc-theme gtk2-engines-murrine gnome-themes-extra adwaita-icon-theme
  # base del escritorio (por si se usa --solo en un sistema nuevo)
  inst polybar bspwm sxhkd fonts-font-awesome fonts-dejavu-core slock
}

# =============================================================================
# MODULO: temas  (paletas + motor "mi-tema")
# =============================================================================
mod_temas() {
  info "[temas] Paletas y motor de temas"

  cat > "$BASE/temas/oscuro.env" <<'EOF'
# Tema OSCURO (basado en Arc-Dark)
NOMBRE="oscuro"
BG="#2f343f";       BG_ALT="#383c4a";  FG="#d3dae3";  DIM="#7c818c"
ACCENT="#5294e2";   ALERT="#e06c75";   BORDER="#404552"
LOCK_BG="#1f232b";  LOCK_PANEL="#2f343f";  WALL="#262a33"
GTK_THEME_PREF="Arc-Dark";  GTK_THEME_FALLBACK="Adwaita-dark";  PREFER_DARK=1
ICON_THEME="Adwaita"
C0="#2f343f";  C1="#e06c75";  C2="#98c379";  C3="#e5c07b"
C4="#5294e2";  C5="#b48ead";  C6="#56b6c2";  C7="#d3dae3"
C8="#4b5162";  C9="#f07178";  C10="#a9d18e"; C11="#f0d399"
C12="#7aa9eb"; C13="#c6a0f6"; C14="#7fcdd8"; C15="#ffffff"
EOF

  cat > "$BASE/temas/claro.env" <<'EOF'
# Tema CLARO (basado en Arc)
NOMBRE="claro"
BG="#f5f6f7";       BG_ALT="#e7e8eb";  FG="#3b3e45";  DIM="#8b9098"
ACCENT="#5294e2";   ALERT="#d1465a";   BORDER="#d3d8e0"
LOCK_BG="#e9ebee";  LOCK_PANEL="#ffffff";  WALL="#dfe2e7"
GTK_THEME_PREF="Arc";  GTK_THEME_FALLBACK="Adwaita";  PREFER_DARK=0
ICON_THEME="Adwaita"
C0="#3b3e45";  C1="#d1465a";  C2="#3f8f3f";  C3="#b5791a"
C4="#3a78c8";  C5="#8a5ba8";  C6="#2e8c97";  C7="#cfd3da"
C8="#7c818c";  C9="#e0626f";  C10="#4da84d"; C11="#c98d2e"
C12="#5294e2"; C13="#a374c0"; C14="#44a5b0"; C15="#ffffff"
EOF

  instala_script mi-tema <<'MITEMA_EOF'
#!/bin/bash
# mi-tema - motor de temas del escritorio
#   mi-tema claro | oscuro | toggle | apply [--boot] | status
# Genera la configuracion de: polybar, rofi, dunst, urxvt, GTK, bspwm y bloqueo
# a partir de la paleta en ~/.config/mi-escritorio/temas/<tema>.env
set -u
BASE="$HOME/.config/mi-escritorio"
CFG="$HOME/.config"
ESTADO="$BASE/tema.actual"

# ---- iconos Font Awesome 4.7 (UTF-8)
I_LAUNCH=$'\xef\x80\x89'; I_CPU=$'\xef\x8b\x9b';  I_MEM=$'\xef\x87\x80'
I_CAL=$'\xef\x81\xb3';    I_PLUG=$'\xef\x87\xa6'; I_POWER=$'\xef\x80\x91'
I_BAT_E=$'\xef\x89\x84'   # vacia
I_BAT_1=$'\xef\x89\x83'   # 1/4
I_BAT_2=$'\xef\x89\x82'   # 1/2
I_BAT_3=$'\xef\x89\x81'   # 3/4
I_BAT_F=$'\xef\x89\x80'   # llena
I_WS1=$'\xef\x84\xa0'; I_WS2=$'\xef\x82\xac'; I_WS3=$'\xef\x84\xa1'
I_WS4=$'\xef\x85\x9c'; I_WS5=$'\xef\x80\x81'

cargar() {
  local f="$BASE/temas/$1.env"
  [ -f "$f" ] || { echo "tema desconocido: $1" >&2; exit 1; }
  . "$f"
  if [ -d "/usr/share/themes/$GTK_THEME_PREF" ]; then GTK_THEME="$GTK_THEME_PREF"
  else GTK_THEME="$GTK_THEME_FALLBACK"; fi
}

# ---------------------------------------------------------------- POLYBAR ---
render_polybar() {
  local cfg="$CFG/polybar/config.ini" S="$CFG/polybar/scripts" M="$BASE/bin"
  local BAT ADP PV RIGHT TRAYBAR="" NUEVO=no
  BAT=$(ls /sys/class/power_supply 2>/dev/null | grep -E '^BAT' | head -1); BAT=${BAT:-BAT0}
  ADP=$(ls /sys/class/power_supply 2>/dev/null | grep -E '^(AC|ADP)' | head -1); ADP=${ADP:-AC}
  PV=$(polybar --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  RIGHT="net audio bt video battery"
  if [ -n "$PV" ] && [ "$(printf '%s\n3.7.0\n' "$PV" | sort -V | head -1)" = "3.7.0" ]; then
    NUEVO=yes; RIGHT="$RIGHT tray"      # polybar >= 3.7: bandeja como modulo (colocable)
  else
    TRAYBAR=$(printf 'tray-position = left\ntray-padding = 4\ntray-background = %s' "$BG")
  fi
  RIGHT="$RIGHT bspwm power"            # escritorios y boton de energia, al final

  mkdir -p "$CFG/polybar/scripts"
  [ -f "$cfg" ] && [ ! -f "$cfg.antes-de-mi-escritorio" ] && cp -a "$cfg" "$cfg.antes-de-mi-escritorio"
  cat > "$CFG/polybar/launch.sh" <<'LAUNCH'
#!/bin/sh
killall -q polybar
while pgrep -u "$(id -u)" -x polybar >/dev/null; do sleep 0.2; done
polybar main >>/tmp/polybar.log 2>&1 &
LAUNCH
  chmod 755 "$CFG/polybar/launch.sh"

  cat > "$cfg" <<EOF
; Generado por mi-tema (tema: $NOMBRE). No editar a mano: edita mi-tema.
[settings]
screenchange-reload = true

[bar/main]
width = 100%
height = 28
fixed-center = true
background = $BG
foreground = $FG
line-size = 2
border-bottom-size = 1
border-bottom-color = $BORDER
padding-left = 2
padding-right = 1
module-margin = 2
font-0 = DejaVu Sans:size=9;3
font-1 = FontAwesome:size=10;3
font-2 = DejaVu Sans:size=10:weight=bold;3
modules-left = launcher cpu memory perf
modules-center = date
modules-right = $RIGHT
cursor-click = pointer
enable-ipc = true
$TRAYBAR

; ---------- IZQUIERDA ----------
[module/launcher]
type = custom/text
content = $I_LAUNCH
content-foreground = $ACCENT
click-left = $M/mi-launcher

[module/cpu]
type = internal/cpu
interval = 3
label = $I_CPU %percentage%%

[module/memory]
type = internal/memory
interval = 5
label = $I_MEM %percentage_used%%

[module/perf]
type = custom/script
exec = /usr/local/bin/perfmode status
interval = 5
click-left = /usr/local/bin/perfmode next

; ---------- CENTRO ----------
[module/date]
type = internal/date
interval = 20
date = %a %d %b
time = %H:%M
label = %{F${DIM}}$I_CAL %date%%{F-}   %{T3}%time%%{T-}

; ---------- DERECHA ----------
[module/net]
type = custom/script
exec = $S/net.sh
interval = 5
click-left = urxvt -e nmtui
click-right = nm-connection-editor

[module/audio]
type = custom/script
exec = $S/audio.sh
interval = 2
click-left = pavucontrol
click-right = $S/audio.sh mute
scroll-up = $S/audio.sh up
scroll-down = $S/audio.sh down

[module/bt]
type = custom/script
exec = $S/bt.sh
interval = 5
click-left = blueman-manager
click-right = $S/bt.sh toggle

[module/video]
type = custom/script
exec = $S/video.sh
interval = 5
click-left = arandr
scroll-up = $S/video.sh up
scroll-down = $S/video.sh down

[module/battery]
type = internal/battery
battery = $BAT
adapter = $ADP
full-at = 98
low-at = 15
poll-interval = 10
format-charging = <label-charging>
label-charging = $I_PLUG %percentage%%
format-discharging = <ramp-capacity> <label-discharging>
label-discharging = %percentage%%
format-low = <ramp-capacity> <label-low>
label-low = %percentage%%
format-low-foreground = $ALERT
format-full = <label-full>
label-full = $I_BAT_F %percentage%%
ramp-capacity-0 = $I_BAT_E
ramp-capacity-1 = $I_BAT_1
ramp-capacity-2 = $I_BAT_2
ramp-capacity-3 = $I_BAT_3
ramp-capacity-4 = $I_BAT_F

[module/bspwm]
type = internal/bspwm
pin-workspaces = false
enable-click = true
enable-scroll = false
ws-icon-0 = 1;$I_WS1
ws-icon-1 = 2;$I_WS2
ws-icon-2 = 3;$I_WS3
ws-icon-3 = 4;$I_WS4
ws-icon-4 = 5;$I_WS5
format = <label-state>
label-focused = %icon%
label-focused-foreground = $ACCENT
label-focused-underline = $ACCENT
label-focused-padding = 1
label-occupied = %icon%
label-occupied-padding = 1
label-empty = %icon%
label-empty-foreground = $DIM
label-empty-padding = 1
label-urgent = %icon%
label-urgent-foreground = $ALERT
label-urgent-underline = $ALERT
label-urgent-padding = 1

[module/power]
type = custom/text
content = $I_POWER
content-foreground = $ALERT
click-left = $M/mi-menu-energia
EOF

  if [ "$NUEVO" = yes ]; then
    cat >> "$cfg" <<EOF

[module/tray]
type = internal/tray
tray-spacing = 6px
tray-size = 14
tray-background = $BG
EOF
  fi
}

# ------------------------------------------------------------------- ROFI ---
render_rofi() {
  mkdir -p "$BASE/rofi"
  local comun
  comun=$(cat <<EOF
* {
    bg:      $BG;
    bg-alt:  $BG_ALT;
    fg:      $FG;
    dim:     $DIM;
    accent:  $ACCENT;
    border:  $BORDER;
    font: "DejaVu Sans 11";
    background-color: transparent;
    text-color: @fg;
}
EOF
)
  # Menu de energia: desplegable bajo el boton (esquina superior derecha)
  cat > "$BASE/rofi/power.rasi" <<EOF
$comun
window {
    location: northeast;
    anchor: northeast;
    x-offset: -8px;
    y-offset: 34px;
    width: 230px;
    background-color: @bg;
    border: 1px;
    border-color: @border;
    padding: 6px;
}
mainbox  { children: [ message, listview ]; spacing: 4px; }
message  { padding: 6px 10px; }
textbox  { text-color: @dim; }
listview { lines: 4; columns: 1; scrollbar: false; fixed-height: false; spacing: 2px; }
element  { padding: 10px 12px; }
element normal.normal, element alternate.normal { background-color: transparent; text-color: @fg; }
element selected.normal { background-color: @accent; text-color: #ffffff; }
element-text { background-color: inherit; text-color: inherit; vertical-align: 0.5; }
EOF
  # Lanzador de aplicaciones: centrado
  cat > "$BASE/rofi/launcher.rasi" <<EOF
$comun
window {
    location: center;
    anchor: center;
    width: 480px;
    background-color: @bg;
    border: 1px;
    border-color: @border;
    padding: 10px;
}
mainbox  { children: [ inputbar, listview ]; spacing: 8px; }
inputbar { padding: 8px 10px; background-color: @bg-alt; children: [ prompt, entry ]; spacing: 8px; }
prompt   { text-color: @accent; }
entry    { placeholder: "Escribe para buscar"; placeholder-color: @dim; }
listview { lines: 8; scrollbar: false; fixed-height: false; spacing: 2px; }
element  { padding: 8px 10px; }
element normal.normal, element alternate.normal { background-color: transparent; text-color: @fg; }
element selected.normal { background-color: @accent; text-color: #ffffff; }
element-text { background-color: inherit; text-color: inherit; }
EOF
}

# ------------------------------------------------------------------ DUNST ---
render_dunst() {
  local f="$CFG/dunst/dunstrc"
  mkdir -p "$CFG/dunst"
  if [ -f "$f" ] && ! grep -q 'mi-escritorio' "$f" && [ ! -f "$f.antes-de-mi-escritorio" ]; then
    cp -a "$f" "$f.antes-de-mi-escritorio"
  fi
  cat > "$f" <<EOF
# mi-escritorio (generado por mi-tema: $NOMBRE)
[global]
    origin = bottom-right
    width = 340
    font = DejaVu Sans 10
    markup = full
    format = "<b>%s</b>\n%b"
    padding = 10
    horizontal_padding = 12
    frame_width = 1
    frame_color = "$BORDER"
    separator_color = frame
    corner_radius = 0
    icon_position = off
    word_wrap = yes
    sort = yes

[urgency_low]
    background = "$BG"
    foreground = "$DIM"
    timeout = 4

[urgency_normal]
    background = "$BG"
    foreground = "$FG"
    timeout = 6

[urgency_critical]
    background = "$BG"
    foreground = "$ALERT"
    frame_color = "$ALERT"
    timeout = 0
EOF
}

# ----------------------------------------------------- TERMINAL (urxvt) ------
render_xres() {
  cat > "$BASE/Xresources.theme" <<EOF
URxvt.background: $BG
URxvt.foreground: $FG
URxvt.cursorColor: $ACCENT
URxvt.color0:  $C0
URxvt.color1:  $C1
URxvt.color2:  $C2
URxvt.color3:  $C3
URxvt.color4:  $C4
URxvt.color5:  $C5
URxvt.color6:  $C6
URxvt.color7:  $C7
URxvt.color8:  $C8
URxvt.color9:  $C9
URxvt.color10: $C10
URxvt.color11: $C11
URxvt.color12: $C12
URxvt.color13: $C13
URxvt.color14: $C14
URxvt.color15: $C15
Xcursor.theme: Adwaita
Xcursor.size: 24
EOF
}

# -------------------------------------------------------------------- GTK ---
render_gtk() {
  mkdir -p "$CFG/gtk-3.0" "$CFG/gtk-4.0" "$CFG/xsettingsd"
  cat > "$CFG/gtk-3.0/settings.ini" <<EOF
[Settings]
gtk-theme-name=$GTK_THEME
gtk-icon-theme-name=$ICON_THEME
gtk-cursor-theme-name=Adwaita
gtk-font-name=DejaVu Sans 9
gtk-application-prefer-dark-theme=$PREFER_DARK
gtk-enable-animations=false
EOF
  cat > "$CFG/gtk-4.0/settings.ini" <<EOF
[Settings]
gtk-icon-theme-name=$ICON_THEME
gtk-cursor-theme-name=Adwaita
gtk-font-name=DejaVu Sans 9
gtk-application-prefer-dark-theme=$PREFER_DARK
gtk-enable-animations=false
EOF
  cat > "$HOME/.gtkrc-2.0" <<EOF
gtk-theme-name="$GTK_THEME"
gtk-icon-theme-name="$ICON_THEME"
gtk-cursor-theme-name="Adwaita"
gtk-font-name="DejaVu Sans 9"
EOF
  # xsettingsd: cambia el tema de las apps GTK abiertas en caliente
  cat > "$CFG/xsettingsd/xsettingsd.conf" <<EOF
Net/ThemeName "$GTK_THEME"
Net/IconThemeName "$ICON_THEME"
Gtk/CursorThemeName "Adwaita"
Gtk/FontName "DejaVu Sans 9"
Gtk/EnableAnimations 0
Net/EnableEventSounds 0
Xft/Antialias 1
Xft/Hinting 1
Xft/HintStyle "hintslight"
Xft/DPI 98304
EOF
}

# ----------------------------------------------------------------- BLOQUEO --
render_lock() {
  local es=""
  es=$(locale -a 2>/dev/null | grep -iE '^es_(pe|mx|es|co|ar|cl)\.utf-?8$' | head -1)
  [ -f "$BASE/rutas.env" ] && . "$BASE/rutas.env"
  {
    echo "# Generado por mi-tema ($NOMBRE) - variables de xsecurelock"
    [ -n "$es" ] && echo "export LC_TIME=\"$es\""
    cat <<EOF
export XSECURELOCK_PAM_SERVICE=xsecurelock
export XSECURELOCK_BACKGROUND_COLOR="$LOCK_BG"
export XSECURELOCK_AUTH_BACKGROUND_COLOR="$LOCK_PANEL"
export XSECURELOCK_AUTH_FOREGROUND_COLOR="$FG"
export XSECURELOCK_AUTH_WARNING_COLOR="$ALERT"
export XSECURELOCK_FONT="DejaVu Sans:size=14"
export XSECURELOCK_SHOW_DATETIME=1
export XSECURELOCK_DATETIME_FORMAT="%A %d %B   %H:%M"
export XSECURELOCK_SHOW_USERNAME=1
export XSECURELOCK_SHOW_HOSTNAME=0
export XSECURELOCK_PASSWORD_PROMPT=asterisks
export XSECURELOCK_AUTH_TIMEOUT=20
export XSECURELOCK_BLANK_TIMEOUT=600
export XSECURELOCK_BLANK_DPMS_STATE=off
export XSECURELOCK_NO_COMPOSITE=1
export XSECURELOCK_DIM_TIME_MS=3000
export XSECURELOCK_WAIT_TIME_MS=5000
export XSECURELOCK_SAVER=${XSL_SAVER:-saver_blank}
export MI_SAVER_BG="$LOCK_BG"
export MI_SAVER_FG="$FG"
export MI_SAVER_ACCENT="$ACCENT"
EOF
  } > "$BASE/lock.env"
}

# ------------------------------------------------------- aplicar en vivo ----
aplicar_vivo() {
  local modo="$1"
  command -v xrdb >/dev/null && xrdb -merge "$BASE/Xresources.theme"
  [ -f "$HOME/.wallpaper" ] || xsetroot -solid "$WALL" 2>/dev/null
  if command -v bspc >/dev/null && pgrep -x bspwm >/dev/null; then
    bspc config normal_border_color  "$BORDER"
    bspc config active_border_color  "$BORDER"
    bspc config focused_border_color "$ACCENT"
    bspc config presel_feedback_color "$ACCENT"
  fi
  if command -v xsettingsd >/dev/null; then
    if pgrep -x xsettingsd >/dev/null; then pkill -HUP -x xsettingsd
    else setsid -f xsettingsd >/dev/null 2>&1; fi
  fi
  if [ "$modo" != "--boot" ]; then
    [ -x "$CFG/polybar/launch.sh" ] && "$CFG/polybar/launch.sh"
    if command -v dunst >/dev/null; then
      pkill -x dunst; setsid -f dunst >/dev/null 2>&1
      sleep 0.4
      notify-send -t 1800 "Tema $NOMBRE" "Aplicado" 2>/dev/null
    fi
  fi
}

aplicar() {
  local nombre="$1" modo="${2:-}"
  cargar "$nombre"
  mkdir -p "$BASE"; echo "$nombre" > "$ESTADO"
  render_polybar; render_rofi; render_dunst; render_xres; render_gtk; render_lock
  [ -n "${DISPLAY:-}" ] && aplicar_vivo "$modo"
  return 0
}

actual() { local t; t=$(cat "$ESTADO" 2>/dev/null); case "$t" in claro|oscuro) echo "$t" ;; *) echo oscuro ;; esac; }

case "${1:-status}" in
  claro|oscuro) aplicar "$1" ;;
  toggle)       [ "$(actual)" = oscuro ] && aplicar claro || aplicar oscuro ;;
  apply|aplicar) aplicar "$(actual)" "${2:-}" ;;
  status)       echo "tema actual: $(actual)" ;;
  *) echo "uso: mi-tema claro|oscuro|toggle|apply [--boot]|status"; exit 1 ;;
esac
MITEMA_EOF
}

# =============================================================================
# MODULO: bloqueo  (xsecurelock + protector de pantalla propio)
# =============================================================================
mod_bloqueo() {
  info "[bloqueo] Pantalla de bloqueo y protector de pantalla"

  # Servicio PAM para xsecurelock (usa la misma autenticacion del sistema)
  if [ ! -f /etc/pam.d/xsecurelock ]; then
    printf '@include common-auth\n@include common-account\n' > /etc/pam.d/xsecurelock
    chmod 644 /etc/pam.d/xsecurelock; ok "PAM: /etc/pam.d/xsecurelock"
  fi

  local blank helpers dimmer saver="saver_blank"
  blank="$(dpkg -L xsecurelock 2>/dev/null | grep '/saver_blank$' | head -1)"
  if [ -n "$blank" ]; then
    helpers="$(dirname "$blank")"
    dimmer="$helpers/dimmer"; [ -x "$dimmer" ] || dimmer=""

    # Protector de pantalla: reloj minimalista que se desplaza (evita marcas en pantalla)
    cat > "$helpers/saver_reloj" <<'SAVER_EOF'
#!/bin/bash
# saver_reloj - protector de pantalla para xsecurelock (reloj que se desplaza)
[ -n "${XSCREENSAVER_WINDOW:-}" ] || exit 1
BG="${MI_SAVER_BG:-#1f232b}"; FG="${MI_SAVER_FG:-#d3dae3}"; AC="${MI_SAVER_ACCENT:-#5294e2}"
exec urxvt -embed "$XSCREENSAVER_WINDOW" +sb -b 0 \
     -bg "$BG" -fg "$FG" -cr "$BG" -bd "$BG" \
     -xrm "URxvt.color4: $AC" \
     -fn "xft:DejaVu Sans Mono:size=44" \
     -e "$(dirname "$0")/saver_reloj.loop"
SAVER_EOF
    cat > "$helpers/saver_reloj.loop" <<'LOOP_EOF'
#!/bin/bash
printf '\e[?25l'
trap 'printf "\e[?25h"' EXIT
while :; do
  read -r filas cols < <(stty size 2>/dev/null || echo "24 80")
  hora=$(date +%H:%M)
  fecha=$(date '+%a %d %b')
  fr=$(( filas > 5  ? RANDOM % (filas - 2)  + 1 : 1 ))
  fc=$(( cols  > 14 ? RANDOM % (cols - 11) + 1 : 1 ))
  printf '\e[2J\e[%d;%dH%s\e[%d;%dH\e[34m%s\e[0m' "$fr" "$fc" "$hora" "$((fr+1))" "$fc" "$fecha"
  sleep 30
done
LOOP_EOF
    chmod 755 "$helpers/saver_reloj" "$helpers/saver_reloj.loop"
    saver="saver_reloj"
    ok "protector de pantalla instalado en $helpers"
  else
    warn "xsecurelock no esta instalado: el bloqueo usara 'slock' (sin diseno)."
    dimmer=""
  fi

  cat > "$BASE/rutas.env" <<EOF
XSL_SAVER="$saver"
XSL_DIMMER="${dimmer:-}"
EOF

  instala_script mi-bloqueo <<'BLOQ_EOF'
#!/bin/bash
# mi-bloqueo - lanza el bloqueo de pantalla (una sola instancia a la vez)
BASE="$HOME/.config/mi-escritorio"
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/mi-bloqueo.lock"
flock -n 9 || exit 0            # ya hay un bloqueo activo
[ -f "$BASE/lock.env" ] && . "$BASE/lock.env"
if command -v xsecurelock >/dev/null 2>&1; then exec xsecurelock; fi
exec slock
BLOQ_EOF
}

# =============================================================================
# MODULO: sesion  (gestor de sesion)
# =============================================================================
mod_sesion() {
  info "[sesion] Gestor de sesion"

  [ -f "$BASE/config.env" ] || cat > "$BASE/config.env" <<'EOF'
# Ajustes de mi-escritorio (edita y reinicia la sesion)
IDLE_BLOQUEO=300     # segundos de inactividad antes de bloquear
IDLE_AVISO=5         # segundos de atenuacion antes del bloqueo
PANTALLA_OFF=600     # segundos de inactividad para apagar la pantalla (DPMS)
CONFIRMAR=yes        # pedir confirmacion para apagar / reiniciar / cerrar sesion
EOF

  # Envoltorio con privilegios, solo para 3 acciones concretas
  cat > /usr/local/sbin/mi-power <<'EOF'
#!/bin/sh
# mi-power poweroff|reboot|suspend  (respaldo si logind/polkit no autoriza)
case "$1" in
  poweroff) sync; exec /sbin/poweroff ;;
  reboot)   sync; exec /sbin/reboot ;;
  suspend)  sync
            if command -v pm-suspend >/dev/null 2>&1; then exec pm-suspend
            else echo mem > /sys/power/state; fi ;;
  *) echo "uso: mi-power poweroff|reboot|suspend" >&2; exit 1 ;;
esac
EOF
  chown root:root /usr/local/sbin/mi-power; chmod 755 /usr/local/sbin/mi-power
  cat > /etc/sudoers.d/mi-power <<EOF
$USUARIO ALL=(root) NOPASSWD: /usr/local/sbin/mi-power poweroff, /usr/local/sbin/mi-power reboot, /usr/local/sbin/mi-power suspend
EOF
  chmod 440 /etc/sudoers.d/mi-power
  visudo -cf /etc/sudoers.d/mi-power >/dev/null || { rm -f /etc/sudoers.d/mi-power; warn "sudoers invalido, eliminado"; }

  # Tapa del portatil -> suspender (elogind). Se aplica tras reiniciar.
  if [ "$LID" = yes ]; then
    mkdir -p /etc/elogind/logind.conf.d
    cat > /etc/elogind/logind.conf.d/10-mi-escritorio.conf <<'EOF'
[Login]
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend
HandleLidSwitchDocked=ignore
HandleSuspendKey=suspend
HandlePowerKey=poweroff
IdleAction=ignore
EOF
    chmod 644 /etc/elogind/logind.conf.d/10-mi-escritorio.conf
    ok "cerrar la tapa suspende el equipo (tras reiniciar)"
  fi

  instala_script mi-sesion <<'SESION_EOF'
#!/bin/bash
# mi-sesion - gestor de sesion
#   lock | suspend | logout | reboot | poweroff | autostart | vigilante | status
BASE="$HOME/.config/mi-escritorio"
BIN="$BASE/bin"
[ -f "$BASE/config.env" ] && . "$BASE/config.env"
[ -f "$BASE/rutas.env" ]  && . "$BASE/rutas.env"

lock_bg() { setsid -f "$BIN/mi-bloqueo" >/dev/null 2>&1; }

sistema() {   # poweroff | reboot  -> logind/elogind; respaldo: sudo
  loginctl --no-ask-password "$1" >/dev/null 2>&1 && return 0
  sudo -n /usr/local/sbin/mi-power "$1"
}

suspender() {
  # Si xss-lock no esta activo, bloqueamos nosotros antes de dormir.
  pgrep -x xss-lock >/dev/null || { lock_bg; sleep 0.5; }
  loginctl --no-ask-password suspend >/dev/null 2>&1 && return 0
  lock_bg; sleep 1
  sudo -n /usr/local/sbin/mi-power suspend
}

cerrar_sesion() {
  if command -v bspc >/dev/null 2>&1; then bspc quit; else pkill -x bspwm; fi
}

# Vigila logind: al dormir y al despertar garantiza que el bloqueo este activo.
vigilante() {
  command -v dbus-monitor >/dev/null 2>&1 || exit 1
  dbus-monitor --system \
    "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" 2>/dev/null |
  while read -r linea; do
    case "$linea" in *"boolean true"*|*"boolean false"*) lock_bg ;; esac
  done
}

autostart() {
  "$BIN/mi-tema" apply --boot
  xset s "${IDLE_BLOQUEO:-300}" "${IDLE_AVISO:-5}"
  xset +dpms; xset dpms 0 0 "${PANTALLA_OFF:-600}"
  pkill -x xss-lock 2>/dev/null
  local n=()
  [ -n "${XSL_DIMMER:-}" ] && [ -x "$XSL_DIMMER" ] && n=(-n "$XSL_DIMMER")
  setsid -f xss-lock --transfer-sleep-lock "${n[@]}" -- "$BIN/mi-bloqueo" >/dev/null 2>&1
  pgrep -f 'mi-sesion vigilante' >/dev/null || setsid -f "$BIN/mi-sesion" vigilante >/dev/null 2>&1
}

estado() {
  local sid act
  echo "tema:            $("$BIN/mi-tema" status)"
  echo "xss-lock:        $(pgrep -x xss-lock >/dev/null && echo activo || echo INACTIVO)"
  echo "vigilante sleep: $(pgrep -f 'mi-sesion vigilante' >/dev/null && echo activo || echo INACTIVO)"
  echo "xsecurelock:     $(command -v xsecurelock || echo 'NO instalado (usa slock)')"
  echo "saver:           ${XSL_SAVER:-?}"
  sid=$(loginctl 2>/dev/null | awk -v u="$USER" '$0 ~ u {print $1; exit}')
  act=$(loginctl show-session "$sid" -p Active 2>/dev/null)
  echo "sesion elogind:  ${act:-no detectada}"
}

case "${1:-}" in
  lock)      lock_bg ;;
  suspend)   suspender ;;
  logout)    cerrar_sesion ;;
  reboot)    sistema reboot ;;
  poweroff)  sistema poweroff ;;
  autostart) autostart ;;
  vigilante) vigilante ;;
  status)    estado ;;
  *) echo "uso: mi-sesion lock|suspend|logout|reboot|poweroff|autostart|vigilante|status"; exit 1 ;;
esac
SESION_EOF
}

# =============================================================================
# MODULO: energia  (menu desplegable + lanzador)
# =============================================================================
mod_energia() {
  info "[energia] Menu de energia y lanzador"

  instala_script mi-menu-energia <<'MENU_EOF'
#!/bin/bash
# mi-menu-energia - menu desplegable: Apagar, Reiniciar, Suspender, Cerrar sesion
BASE="$HOME/.config/mi-escritorio"
[ -f "$BASE/config.env" ] && . "$BASE/config.env"
TEMA="$BASE/rofi/power.rasi"
SES="$BASE/bin/mi-sesion"

# alternar: si el menu ya esta abierto, cerrarlo
pgrep -x rofi >/dev/null && { pkill -x rofi; exit 0; }

I_OFF=$'\xef\x80\x91'; I_REB=$'\xef\x80\xa1'; I_SLP=$'\xef\x86\x86'
I_OUT=$'\xef\x82\x8b'; I_OK=$'\xef\x80\x8c';  I_NO=$'\xef\x80\x8d'

menu() {   # menu "mensaje" opcion1 opcion2 ...  -> imprime el indice elegido
  local msg="$1"; shift
  local args=(-dmenu -i -no-custom -format i -theme "$TEMA" -p '' \
              -me-select-entry '' -me-accept-entry MousePrimary)
  [ -n "$msg" ] && args+=(-mesg "$msg")
  printf '%s\n' "$@" | rofi "${args[@]}"
}

confirmar() {   # confirmar "pregunta"
  [ "${CONFIRMAR:-yes}" = yes ] || return 0
  local r; r=$(menu "$1" "$I_OK   Confirmar" "$I_NO   Cancelar")
  [ "$r" = "0" ]
}

sel=$(menu "" "$I_OFF   Apagar" "$I_REB   Reiniciar" "$I_SLP   Suspender" "$I_OUT   Cerrar sesión")
case "$sel" in
  0) confirmar "¿Apagar el sistema?"    && "$SES" poweroff ;;
  1) confirmar "¿Reiniciar el sistema?" && "$SES" reboot ;;
  2) "$SES" suspend ;;
  3) confirmar "¿Cerrar la sesión?"     && "$SES" logout ;;
esac
MENU_EOF

  instala_script mi-launcher <<'LAUNCH_EOF'
#!/bin/bash
# mi-launcher - lanzador de aplicaciones (rofi, sin iconos para ir mas rapido)
BASE="$HOME/.config/mi-escritorio"
pgrep -x rofi >/dev/null && { pkill -x rofi; exit 0; }
exec rofi -show drun -no-show-icons -theme "$BASE/rofi/launcher.rasi" -display-drun "Buscar"
LAUNCH_EOF
}

# =============================================================================
# MODULO: panel  (comprobaciones; el diseno lo genera mi-tema)
# =============================================================================
mod_panel() {
  info "[panel] Comprobando componentes del panel"
  local s
  for s in net.sh audio.sh bt.sh video.sh; do
    [ -f "$HOME_DIR/.config/polybar/scripts/$s" ] || \
      warn "falta ~/.config/polybar/scripts/$s (ejecuta antes setup-t61.sh); ese modulo saldra vacio"
  done
  [ -x /usr/local/bin/perfmode ] || warn "falta /usr/local/bin/perfmode (de setup-t61.sh): el modulo de rendimiento saldra vacio"
  command -v polybar >/dev/null || warn "polybar no esta instalado"
}

# =============================================================================
# MODULO: integracion  (bspwmrc, sxhkdrc, enlaces, aplicar tema)
# =============================================================================
mod_integracion() {
  info "[integracion] Conectando todo con bspwm y sxhkd"

  # ---- bspwmrc
  local rc="$HOME_DIR/.config/bspwm/bspwmrc"
  if [ -f "$rc" ]; then
    bk "$rc"
    sed -i -e '/^xset s 300 300/d' -e '/xss-lock -- slock/d' "$rc"
    if ! grep -q '>>> mi-escritorio >>>' "$rc"; then
      cat >> "$rc" <<'EOF'

# >>> mi-escritorio >>>
"$HOME/.config/mi-escritorio/bin/mi-sesion" autostart &
# <<< mi-escritorio <<<
EOF
    fi
    ok "bspwmrc actualizado"
  else
    warn "no existe $rc (ejecuta antes setup-t61.sh)."
  fi

  # ---- sxhkdrc (se quitan chocantes y se anade bloque gestionado)
  local sx="$HOME_DIR/.config/sxhkd/sxhkdrc"
  if [ -f "$sx" ]; then
    bk "$sx"
    awk -v drop="super + d|super + x|super + shift + x|super + alt + t|XF86Sleep|XF86ScreenSaver" '
      BEGIN { n = split(drop, a, "|"); for (i = 1; i <= n; i++) D[a[i]] = 1 }
      /^# >>> mi-escritorio >>>/ { blk = 1 }
      blk { if ($0 ~ /^# <<< mi-escritorio <<</) blk = 0; next }
      /^[^[:space:]#]/ { skip = ($0 in D) }
      /^[[:space:]]*$/ { skip = 0 }
      skip { next }
      { print }
    ' "$sx" > "$sx.nuevo" && mv "$sx.nuevo" "$sx"
    cat >> "$sx" <<'EOF'

# >>> mi-escritorio >>>
super + d
    ~/.config/mi-escritorio/bin/mi-launcher
super + x
    ~/.config/mi-escritorio/bin/mi-menu-energia
super + shift + x
    ~/.config/mi-escritorio/bin/mi-sesion lock
super + alt + t
    ~/.config/mi-escritorio/bin/mi-tema toggle
XF86Sleep
    ~/.config/mi-escritorio/bin/mi-sesion suspend
XF86ScreenSaver
    ~/.config/mi-escritorio/bin/mi-sesion lock
# <<< mi-escritorio <<<
EOF
    ok "sxhkdrc actualizado"
  else
    warn "no existe $sx (ejecuta antes setup-t61.sh)."
  fi

  # ---- comandos accesibles desde la terminal
  local c
  for c in mi-tema mi-sesion mi-bloqueo mi-menu-energia mi-launcher; do
    [ -x "$BIN/$c" ] && ln -sf "$BIN/$c" "$HOME_DIR/.local/bin/$c"
  done
}

# =============================================================================
# Ejecutar modulos
# =============================================================================
for m in $MODULOS; do quiere "$m" && "mod_$m"; done

# ---- Aplicar tema (genera panel, rofi, dunst, GTK, bloqueo...) como el usuario
info "Aplicando tema inicial: $TEMA_INICIAL"
chown -R "$USUARIO:$GRP" "$BASE" "$HOME_DIR/.local" "$HOME_DIR/.config" 2>/dev/null
if [ -x "$BIN/mi-tema" ]; then
  [ -f "$BASE/tema.actual" ] && [ -n "$SOLO" ] && TEMA_INICIAL="$(cat "$BASE/tema.actual")"
  runuser -u "$USUARIO" -- env HOME="$HOME_DIR" "$BIN/mi-tema" "$TEMA_INICIAL" \
    && ok "tema $TEMA_INICIAL generado" || warn "mi-tema devolvio un error; revisa $LOG"
fi
chown -R "$USUARIO:$GRP" "$BASE" "$HOME_DIR/.local" "$HOME_DIR/.config" "$HOME_DIR/.gtkrc-2.0" 2>/dev/null

# =============================================================================
# Resumen
# =============================================================================
echo
echo "${C_G}============================  LISTO  ============================${C_0}"
[ "${#FAILED[@]}" -gt 0 ] && warn "No se instalaron: ${FAILED[*]}  (busca el nombre: apt-cache search <nombre>)"
echo "1) Reinicia ($USUARIO): 'reboot'  (o cierra la sesion con super+alt+q y vuelve a entrar)"
echo "2) Atajos nuevos:"
echo "     super+d          lanzador de aplicaciones"
echo "     super+x          menu de energia (tambien el boton rojo del panel)"
echo "     super+shift+x    bloquear pantalla"
echo "     super+alt+t      alternar tema claro/oscuro"
echo "3) Comandos:  mi-tema claro|oscuro|toggle   mi-sesion status|lock|suspend|logout"
echo "4) Prueba el bloqueo:  mi-sesion lock   y luego   mi-sesion suspend"
echo "5) Ajustes (tiempos, confirmaciones):  ~/.config/mi-escritorio/config.env"
echo "Backups: $BK     Log: $LOG"