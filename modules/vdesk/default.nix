{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.vdesk;

  # 声明式数据：生成 sway 配置。改这里必须 home-manager switch（跟以前放 store 里的行为一致）。
  swayConf = pkgs.writeTextFile {
    name = "vdesk-sway.conf";
    text = ''
      # 由 modules/vdesk/default.nix 生成，不要手改。
      # 初始分辨率只是占位：noVNC 用 resize=remote 连上来后，wayvnc 会把输出改成客户端视口大小。
      output ${cfg.output} resolution ${cfg.resolution} mode ${cfg.resolution}

      # WSL 里 /tmp/.X11-unix 没有 sticky bit，wlroots 会拒绝启动 Xwayland。
      # 真需要跑 X11 老应用时：sudo chmod 1777 /tmp/.X11-unix，然后设 vdesk.xwayland = true。
      xwayland ${if cfg.xwayland then "enable" else "disable"}

      default_border pixel ${toString cfg.borderWidth}
      default_floating_border pixel ${toString cfg.borderWidth}
      gaps inner ${toString cfg.gaps}
      gaps outer ${toString cfg.gaps}
      focus_follows_mouse no

      # 从浏览器里按 Windows 键会被宿主截走，所以默认用 Alt。
      set $mod ${cfg.mod}
      bindsym $mod+Return exec ${cfg.terminal}
      bindsym $mod+Shift+q kill
      bindsym $mod+f fullscreen toggle
      bindsym $mod+Shift+e exit

      exec ${cfg.terminal}

      ${cfg.extraConfig}
    '';
  };

  # 脚本本体是独立文件，不进 Nix 字符串：这样才能单独 shellcheck / diff / 高亮。
  vdesk = pkgs.writeShellApplication {
    name = "vdesk";
    runtimeInputs = with pkgs; [
      sway
      grim
      wayvnc
      python3Packages.websockify
      python3Packages.vncdotool
      wl-clipboard
      novnc
      jq
      iproute2
      foot
    ]
    ++ lib.optional cfg.xwayland xwayland;
    text = ''
      export VDESK_NOVNC_WEB="${pkgs.novnc}/share/webapps/novnc"
      export VDESK_SWAY_CONF="${swayConf}"
      ${builtins.readFile ./vdesk.sh}
    '';
  };
in
{
  options.vdesk = {
    enable = lib.mkEnableOption "vdesk 无头 Wayland 桌面（sway + wayvnc + noVNC）";

    output = lib.mkOption {
      type = lib.types.str;
      default = "HEADLESS-1";
      description = "headless 输出名";
    };

    resolution = lib.mkOption {
      type = lib.types.str;
      default = "1600x1000";
      description = "没有 noVNC 客户端连接时的初始分辨率";
    };

    mod = lib.mkOption {
      type = lib.types.str;
      default = "Mod1";
      description = "sway 的 $mod 修饰键（Mod1 = Alt，Mod4 = Super）";
    };

    terminal = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.foot}/bin/foot";
      description = "桌面默认终端命令，也是 Mod+Return 绑定";
    };

    xwayland = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "是否启用 Xwayland（WSL 下需先给 /tmp/.X11-unix 加 sticky bit）";
    };

    gaps = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = "窗口间距";
    };

    borderWidth = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "窗口边框宽度";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "追加到 sway 配置末尾的原始内容";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ vdesk ];

    systemd.user.services."vdesk@" = {
      Unit.Description = "vdesk headless Wayland screen %i";
      Service = {
        Type = "simple";
        ExecStart = "${vdesk}/bin/vdesk run %i";
        Restart = "on-failure";
        RestartSec = 3;
        RuntimeDirectory = "vdesk/%i";
        RuntimeDirectoryMode = "0700";
        KillMode = "control-group";
        TimeoutStopSec = 5;
        # 桌面里的终端不再打 MOTD（zshrc 里 PT_PMOTD2_RUN 已设就跳过 pmotd2）。
        Environment = [ "PT_PMOTD2_RUN=yes" ];
      };
    };
  };
}
