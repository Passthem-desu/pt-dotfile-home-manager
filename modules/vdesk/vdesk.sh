# vdesk — 一块可看、可点、可截屏的无头 Wayland 桌面。
# 一个屏幕 = 一个 systemd unit（vdesk@<name>）= sway + wayvnc + noVNC。

# 不用 ${XDG_RUNTIME_DIR}：在屏幕内部（foot 里）跑 vdesk 时它会被改到屏幕自己的目录。
RUNTIME_ROOT="/run/user/$(id -u)/vdesk"
OUTPUT="${VDESK_OUTPUT:-HEADLESS-1}"
SHOT_DIR="${VDESK_SHOT_DIR:-$HOME/screens/shots}"

die() { printf 'vdesk: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: vdesk <命令> [参数]

  new <name>                起一块屏幕，打印 noVNC 地址
  watch <name>              在 Kero 浏览器 pane 里打开（无 kero 则只打印地址）
  ls                        列出正在运行的屏幕
  url <name>               打印 noVNC 地址
  stop <name>               停掉一块屏幕（桌面状态不保留）
  log <name>                看这块屏幕的日志

  shot <name> [--hi]        截屏到 ~/screens/shots/，--hi 临时抬分辨率再还原
  win <name>                列出窗口（id / app_id / 几何 / 标题，* = 有焦点）
  ipc <name> <swaymsg 参数> 直通 swaymsg，如 ipc work -t get_workspaces
  focus <name> <模式>       聚焦 app_id 或标题匹配的窗口
  exec <name> <命令...>     在桌面里跑一个程序

  type <name> <文本>        打字
  key <name> <组合键>       如 Return / Tab / ctrl+c
  move <name> <x> <y>       移动指针
  click <name> <x> <y> [左键]  移动并点击（按钮默认 left）
  scroll <name> <x> <y>     滚动

  run <name>                systemd 入口，前台跑整块屏幕（不直接调用）
EOF
}

runtime_of() { printf '%s/%s' "$RUNTIME_ROOT" "$1"; }

wayland_display() {
  local rt=$1 wd f
  if wd=$(cat "$rt/wayland-display" 2>/dev/null) && [ -n "$wd" ]; then
    printf '%s' "$wd"
    return 0
  fi
  for f in "$rt"/wayland-[0-9]*; do
    if [ -S "$f" ]; then
      printf '%s' "$(basename "$f")"
      return 0
    fi
  done
  return 1
}

sway_sock() {
  local rt=$1 f
  for f in "$rt"/sway-ipc.*.sock; do
    if [ -S "$f" ]; then
      printf '%s' "$f"
      return 0
    fi
  done
  return 1
}

screen_env() {
  local name=$1 rt wd sock
  rt=$(runtime_of "$name")
  [ -d "$rt" ] || die "屏幕 $name 未运行（vdesk new $name）"
  wd=$(wayland_display "$rt") || die "屏幕 $name 的 wayland socket 还没就绪"
  export XDG_RUNTIME_DIR="$rt" XDG_SESSION_TYPE=wayland WAYLAND_DISPLAY="$wd"
  if sock=$(sway_sock "$rt"); then export SWAYSOCK="$sock"; fi
}

url_of() {
  local name=$1 rt web
  rt=$(runtime_of "$name")
  web=$(cat "$rt/web-port" 2>/dev/null) || return 1
  [ -n "$web" ] || return 1
  printf 'http://localhost:%s/vnc.html?autoconnect=1&resize=remote\n' "$web"
}

port_busy() {
  local p=$1
  if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
    return 0
  fi
  return 1
}

free_port() {
  local lo=$1 hi=$2 p
  for ((p = lo; p <= hi; p++)); do
    if ! port_busy "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

output_size() {
  swaymsg -t get_outputs | jq -r --arg out "$OUTPUT" \
    '[.[] | select(.name == $out)][0] | "\(.rect.width) \(.rect.height)"'
}

cmd_new() {
  local name=$1 rt i
  rt=$(runtime_of "$name")
  systemctl --user start "vdesk@$name" || die "启动失败：journalctl --user -u vdesk@$name -n 40"
  for i in {1..100}; do
    if [ -s "$rt/web-port" ]; then break; fi
    sleep 0.1
  done
  [ -s "$rt/web-port" ] || die "屏幕 $name 启动超时：journalctl --user -u vdesk@$name -n 40"
  url_of "$name" || die "读不到 $name 的端口"
}

cmd_watch() {
  local name=$1 url
  url=$(url_of "$name") || die "屏幕 $name 未运行（vdesk new $name）"
  if command -v kero >/dev/null; then
    kero split --url "$(printf '%s' "$url")"
  fi
  printf '%s\n' "$url"
}

cmd_ls() {
  local unit name rt res state vnc web
  local -a units
  mapfile -t units < <(systemctl --user list-units 'vdesk@*.service' --no-legend --plain 2>/dev/null | awk '{print $1}')
  if [ ${#units[@]} -eq 0 ]; then
    echo "没有运行中的屏幕（vdesk new <name>）"
    return 0
  fi
  printf '%-12s %-8s %-12s %-6s %s\n' NAME STATE 分辨率 VNC URL
  for unit in "${units[@]}"; do
    name=${unit#vdesk@}
    name=${name%.service}
    rt=$(runtime_of "$name")
    state=$(systemctl --user is-active "vdesk@$name")
    res="-"
    if [ -d "$rt" ]; then
      res=$(screen_env "$name" >/dev/null 2>&1 && output_size 2>/dev/null) || res="-"
    fi
    vnc=$(cat "$rt/wayvnc-port" 2>/dev/null || echo -)
    web=$(cat "$rt/web-port" 2>/dev/null || echo -)
    printf '%-12s %-8s %-12s %-6s http://localhost:%s/vnc.html\n' "$name" "$state" "$res" "$vnc" "$web"
  done
}

cmd_stop() {
  local name=$1
  systemctl --user stop "vdesk@$name" || die "停止失败"
  printf '已停止: %s（桌面状态不保留）\n' "$name"
}

cmd_log() {
  local name=$1
  journalctl --user -u "vdesk@$name" -n "${2:-50}" --no-pager
}

cmd_shot() {
  local name=$1 mode=${2:-} out cur_w cur_h hi_w hi_h
  screen_env "$name"
  mkdir -p "$SHOT_DIR"
  out="$SHOT_DIR/$name-$(date +%Y%m%d-%H%M%S).png"
  if [ "$mode" = "--hi" ]; then
    read -r cur_w cur_h <<<"$(output_size)"
    hi_w=2000
    hi_h=$((cur_h * hi_w / cur_w))
    swaymsg output "$OUTPUT" resolution "${hi_w}x${hi_h}" >/dev/null
    sleep 0.4
    if ! grim -o "$OUTPUT" "$out"; then
      swaymsg output "$OUTPUT" resolution "${cur_w}x${cur_h}" >/dev/null
      die "截图失败"
    fi
    swaymsg output "$OUTPUT" resolution "${cur_w}x${cur_h}" >/dev/null
  else
    grim -o "$OUTPUT" "$out" || die "截图失败"
  fi
  printf '%s\n' "$out"
}

cmd_win() {
  local name=$1
  screen_env "$name"
  swaymsg -t get_tree | jq -r '
    .. | objects | select(has("app_id")) | select(.app_id != null)
    | "\(if .focused then "*" else " " end)\(.id)\t\(.app_id)\t\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)\t\(.name)"'
}

cmd_focus() {
  local name=$1 pattern=$2 id
  screen_env "$name"
  id=$(swaymsg -t get_tree | jq -r --arg p "$pattern" '
    .. | objects | select(has("app_id")) | select(.app_id != null)
    | select((.app_id == $p) or ((.name // "") | test($p)))
    | .id' | head -1)
  [ -n "$id" ] || die "没找到窗口: $pattern"
  swaymsg "[con_id=$id]" focus >/dev/null
  printf '已聚焦: %s\n' "$id"
}

cmd_ipc() {
  local name=${1:?缺少 name}
  shift
  screen_env "$name"
  swaymsg "$@"
}

cmd_exec() {
  local name=${1:?缺少 name}
  shift
  [ $# -gt 0 ] || die "exec 需要一个命令"
  screen_env "$name"
  swaymsg exec -- "$*" >/dev/null
}

cmd_type() {
  local name=${1:?缺少 name}
  shift
  [ $# -gt 0 ] || die "type 需要文本"
  screen_env "$name"
  wtype -s 12 "$*"
}

cmd_key() {
  local name=$1 combo=$2
  local -a parts args=()
  local i n
  screen_env "$name"
  IFS='+' read -r -a parts <<<"$combo"
  n=${#parts[@]}
  for ((i = 0; i < n - 1; i++)); do args+=(-M "${parts[i]}"); done
  args+=(-k "${parts[n - 1]}")
  for ((i = n - 2; i >= 0; i--)); do args+=(-m "${parts[i]}"); done
  wtype "${args[@]}"
}

cmd_move() {
  local name=$1 x=$2 y=$3
  screen_env "$name"
  wlrctl pointer move "$x" "$y"
}

cmd_click() {
  local name=$1 x=$2 y=$3 button=${4:-left}
  screen_env "$name"
  wlrctl pointer move "$x" "$y"
  sleep 0.15
  wlrctl pointer click "$button"
}

cmd_scroll() {
  local name=$1 x=$2 y=$3
  screen_env "$name"
  wlrctl pointer scroll "$x" "$y"
}

cmd_url() {
  url_of "$1" || die "屏幕 $1 未运行（vdesk new $1）"
}

# systemd 入口：前台跑 sway，wayvnc / websockify 作为子进程，退出时一起收掉。
cmd_run() {
  local name=$1 rt vnc_port web_port wd i sway_pid
  rt=$(runtime_of "$name")
  mkdir -p "$rt"
  chmod 700 "$rt"
  vnc_port=$(free_port 5901 5999) || die "5901-5999 没有空闲端口"
  web_port=$(free_port 6081 6199) || die "6081-6199 没有空闲端口"
  printf '%s\n' "$vnc_port" >"$rt/wayvnc-port"
  printf '%s\n' "$web_port" >"$rt/web-port"

  export XDG_RUNTIME_DIR="$rt" XDG_SESSION_TYPE=wayland
  unset WAYLAND_DISPLAY
  export WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=pixman

  # 不用 trap 收子进程：Type=simple + KillMode=control-group 下，主进程退出时
  # systemd 会把整个 cgroup 一起收掉，自己写 cleanup 反而会和 set -u/局部变量打架。
  sway -c "${VDESK_SWAY_CONF:?}" &
  sway_pid=$!

  wd=""
  for i in {1..100}; do
    wd=$(wayland_display "$rt") || wd=""
    if [ -n "$wd" ]; then break; fi
    sleep 0.1
  done
  [ -n "$wd" ] || die "sway 没起来"

  printf '%s\n' "$wd" >"$rt/wayland-display"
  export WAYLAND_DISPLAY="$wd"

  wayvnc -r -f 30 "127.0.0.1:$vnc_port" &
  websockify --web "${VDESK_NOVNC_WEB:?}" "127.0.0.1:$web_port" "127.0.0.1:$vnc_port" &

  wait "$sway_pid"
}

main() {
  local cmd=${1:-}
  [ $# -gt 0 ] && shift
  case "$cmd" in
  new) cmd_new "${1:?缺少 name}" ;;
  watch) cmd_watch "${1:?缺少 name}" ;;
  ls) cmd_ls ;;
  url) cmd_url "${1:?缺少 name}" ;;
  stop) cmd_stop "${1:?缺少 name}" ;;
  log) cmd_log "${1:?缺少 name}" ;;
  shot) cmd_shot "${1:?缺少 name}" "${2:-}" ;;
  win) cmd_win "${1:?缺少 name}" ;;
  focus) cmd_focus "${1:?缺少 name}" "${2:?缺少模式}" ;;
  ipc) cmd_ipc "$@" ;;
  exec) cmd_exec "$@" ;;
  type) cmd_type "$@" ;;
  key) cmd_key "${1:?缺少 name}" "${2:?缺少组合键}" ;;
  move) cmd_move "${1:?缺少 name}" "${2:?缺少 x}" "${3:?缺少 y}" ;;
  click) cmd_click "${1:?缺少 name}" "${2:?缺少 x}" "${3:?缺少 y}" "${4:-left}" ;;
  scroll) cmd_scroll "${1:?缺少 name}" "${2:?缺少 x}" "${3:?缺少 y}" ;;
  run) cmd_run "${1:?缺少 name}" ;;
  -h | --help | help | "") usage ;;
  *) die "未知命令: $cmd（vdesk --help）" ;;
  esac
}

main "$@"
