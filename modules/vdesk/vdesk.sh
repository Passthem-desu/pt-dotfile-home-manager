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

  type <name> <文本>        打字（非 ASCII 自动改用剪贴板粘贴）
  key <name> <组合键>       如 Return / Tab / ctrl+c
  move <name> <x> <y>       移动指针
  click <name> <x> <y> [按钮]  移动并点击（left/middle/right）
  drag <name> <x1> <y1> <x2> <y2> [步数]  按住拖动
  scroll <name> <x> <y> [up|down|left|right] [次数]  滚动

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

# free_port 只能回答『此刻没人监听』，而从探到 bind 之间还隔着 sway 启动那段窗口：
# 两块屏同时起会挑中同一个端口。所以自己绑，再回头确认监听者就是这个子进程
# （bind 失败时 wayvnc / websockify 会当场退出，端口文件要是照写就成了谎话）。
port_owner() {
  ss -Hltnp "sport = :$1" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1
}

wait_bind() {
  local port=$1 pid=$2 i
  for i in {1..60}; do
    kill -0 "$pid" 2>/dev/null || return 1
    [ "$(port_owner "$port")" = "$pid" ] && return 0
    sleep 0.05
  done
  return 1
}

bind_or_kill() {
  local port=$1 pid=$2
  wait_bind "$port" "$pid" && return 0
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
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

# vncdotool 的 pause 参数单位是秒（直接喂 reactor.callLater）。
# 新连接第一次发键前，wayvnc 才把它的 xkb keymap 传给合成器并同步给 Xwayland，
# 不等这段时间的话第一个按键会被丢掉——所以发键前先停一下。
VNC_SETTLE="${VDESK_VNC_SETTLE:-0.35}"

# 指针位置同样不是同步上报的（wayvnc 按帧批量送）：move 紧跟按钮事件时，按下会被
# 算在旧坐标上——click 落在上一次的位置，两点短笔画直接退化成原地一个点。
VNC_POINTER_SETTLE="${VDESK_VNC_POINTER_SETTLE:-0.05}"

# 输入注入只能走 wayvnc 的 RFB 口：wayvnc 自己持着常驻的虚拟指针/键盘。
# wlrctl 那种一次性客户端每条命令新建一个设备，进程退出时设备销毁、合成器会清掉
# pointer focus，button 直接丢；Xwayland 的 XTEST 又因为 nixpkgs 的 wlroots 没编
# libei 而被丢弃（日志里的 "[xwayland ei] Setup failed"）；uinput 更不行——
# headless 后端没有 libinput，内核输入设备进不了合成器。
vnc_do() {
  local name=$1 rt port
  shift
  rt=$(runtime_of "$name")
  port=$(cat "$rt/wayvnc-port" 2>/dev/null) || port=""
  [ -n "$port" ] || die "屏幕 $name 未运行（vdesk new $name）"
  timeout "${VDESK_VNC_TIMEOUT:-20}" \
    vncdo -s "127.0.0.1::$port" --delay 20 "$@" </dev/null ||
    die "输入注入失败：$name"
}

button_num() {
  case "$1" in
  left | 1) printf 1 ;;
  middle | 2) printf 2 ;;
  right | 3) printf 3 ;;
  *) die "未知按钮: $1（left/middle/right）" ;;
  esac
}

# sway 风格的键名 → vncdo 的 keysym 记号（KEYMAP 只认小写单词或单字符）。
key_token() {
  local k=${1,,}
  case "$k" in
  return | enter) printf return ;;
  escape | esc) printf esc ;;
  tab) printf tab ;;
  space) printf space ;;
  backspace | bsp) printf bsp ;;
  delete | del) printf delete ;;
  home) printf home ;;
  end) printf end ;;
  pageup | pgup) printf pgup ;;
  pagedown | pgdn) printf pgdn ;;
  left | right | up | down) printf '%s' "$k" ;;
  f[1-9] | f[12][0-9] | f2[0-4]) printf '%s' "$k" ;;
  *) printf '%s' "$1" ;;
  esac
}

mod_token() {
  case "${1,,}" in
  ctrl | control) printf ctrl ;;
  alt | mod1) printf alt ;;
  shift) printf shift ;;
  super | mod4) printf super ;;
  meta) printf meta ;;
  *) die "未知修饰键: $1（ctrl/alt/shift/super）" ;;
  esac
}

# RFB 的 keysym 只有 ASCII 能直接发；其它字符走剪贴板 + ctrl+v。
# 不能用 vncdo 自带的 pastefile（ClientCutText）——wayvnc 会直接断掉连接；
# 换成 wl-copy 设置 Wayland 剪贴板，Xwayland 自己会把选区桥接给 X11 应用。
cmd_type() {
  local name=${1:?缺少 name} text
  shift
  [ $# -gt 0 ] || die "type 需要文本"
  text="$*"
  if LC_ALL=C grep -q '[^ -~]' <<<"$text"; then
    screen_env "$name"
    wl-copy "$text"
    vnc_do "$name" pause "$VNC_SETTLE" key ctrl-v
  else
    vnc_do "$name" pause "$VNC_SETTLE" type "$text"
  fi
}

cmd_key() {
  local name=$1 combo=$2
  local -a parts=() toks=()
  local i n joined
  IFS='+' read -r -a parts <<<"$combo"
  n=${#parts[@]}
  for ((i = 0; i < n - 1; i++)); do toks+=("$(mod_token "${parts[i]}")"); done
  toks+=("$(key_token "${parts[n - 1]}")")
  joined=$(IFS=-; printf '%s' "${toks[*]}")
  vnc_do "$name" pause "$VNC_SETTLE" key "$joined"
}

cmd_move() {
  vnc_do "$1" move "$2" "$3"
}

cmd_click() {
  vnc_do "$1" move "$2" "$3" pause "$VNC_POINTER_SETTLE" click "$(button_num "${4:-left}")"
}

cmd_drag() {
  local name=$1 x1=$2 y1=$3 x2=$4 y2=$5 steps=${6:-12}
  local -a acts=(move "$x1" "$y1" pause "$VNC_POINTER_SETTLE" mousedown 1)
  local i x y
  for ((i = 1; i <= steps; i++)); do
    x=$((x1 + (x2 - x1) * i / steps))
    y=$((y1 + (y2 - y1) * i / steps))
    acts+=(move "$x" "$y")
  done
  acts+=(mouseup 1)
  vnc_do "$name" "${acts[@]}"
}

# RFB 没有滚动事件，滚轮就是 button 4/5（横向 6/7）。
cmd_scroll() {
  local name=$1 x=$2 y=$3 dir=${4:-down} n=${5:-1}
  local -a acts=(move "$x" "$y" pause "$VNC_POINTER_SETTLE")
  local i btn
  case "$dir" in
  up) btn=4 ;;
  down) btn=5 ;;
  left) btn=6 ;;
  right) btn=7 ;;
  *) die "scroll 方向需要 up/down/left/right" ;;
  esac
  for ((i = 0; i < n; i++)); do acts+=(click "$btn"); done
  vnc_do "$name" "${acts[@]}"
}

cmd_url() {
  url_of "$1" || die "屏幕 $1 未运行（vdesk new $1）"
}

# systemd 入口：前台跑 sway，wayvnc / websockify 作为子进程，退出时一起收掉。
cmd_run() {
  local name=$1 rt vnc_port web_port wd i sway_pid vnc_pid web_pid p
  rt=$(runtime_of "$name")
  mkdir -p "$rt"
  chmod 700 "$rt"
  # 端口文件是就绪标记而不是配置：先清掉上次运行剩下的，否则 cmd_new 会读到假地址。
  rm -f "$rt/wayvnc-port" "$rt/web-port"

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

  # 先把 wayvnc 的端口绑死在自己手里，再挑 web 端口：这样 websockify 反代的目标
  # 不可能被另一块屏复用走。重试拿的是下一个候选端口，绝不回收已确认的那个。
  vnc_port=""
  for _ in {1..5}; do
    p=$(free_port 5901 5999) || break
    wayvnc -r -f 30 "127.0.0.1:$p" &
    vnc_pid=$!
    if bind_or_kill "$p" "$vnc_pid"; then
      vnc_port=$p
      break
    fi
  done
  [ -n "$vnc_port" ] || die "wayvnc 没绑上端口（5901-5999）"

  web_port=""
  for _ in {1..5}; do
    p=$(free_port 6081 6199) || break
    websockify --web "${VDESK_NOVNC_WEB:?}" "127.0.0.1:$p" "127.0.0.1:$vnc_port" &
    web_pid=$!
    if bind_or_kill "$p" "$web_pid"; then
      web_port=$p
      break
    fi
  done
  [ -n "$web_port" ] || die "websockify 没绑上端口（6081-6199）"

  printf '%s\n' "$vnc_port" >"$rt/wayvnc-port"
  printf '%s\n' "$web_port" >"$rt/web-port"

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
  drag) cmd_drag "${1:?缺少 name}" "${2:?缺少 x1}" "${3:?缺少 y1}" "${4:?缺少 x2}" "${5:?缺少 y2}" "${6:-12}" ;;
  scroll) cmd_scroll "${1:?缺少 name}" "${2:?缺少 x}" "${3:?缺少 y}" "${4:-down}" "${5:-1}" ;;
  run) cmd_run "${1:?缺少 name}" ;;
  -h | --help | help | "") usage ;;
  *) die "未知命令: $cmd（vdesk --help）" ;;
  esac
}

main "$@"
