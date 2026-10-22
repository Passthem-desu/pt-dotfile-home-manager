{ pkgs, config, ... }:

{
  home.username = "passthem";
  home.homeDirectory = "/home/passthem";

  home.stateVersion = "26.05";

  programs.home-manager.enable = true;
  programs.git = {
    enable = true;
    signing = {
      key = "E5FE60726B0803D5D1890F18960E9B89020CDD5D";
      signByDefault = true;
    };
    lfs.enable = true;
    settings = {
      user.name = "passthem";
      user.email = "Passthem183@gmail.com";
      init.defaultBranch = "main";
      push.autoSetupRemote = true;
      pull.rebase = false;
      core.editor = "nvim";
      merge.tool = "nvimdiff";
      mergetool.keepBackup = false;
    };
  };
  programs.gh = {
    enable = true;
    settings.git_protocol = "https";
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    enableNushellIntegration = false;
    silent = true;
  };

  home.file.".config/zsh/fzf-tab".source = pkgs.runCommand "fzf-tab-no-module" { } ''
    mkdir -p $out
    cp -r ${pkgs.zsh-fzf-tab}/share/fzf-tab/. $out/
    chmod -R u+w $out
    rm -rf $out/modules
  '';

  home.file.".config/zsh/plugins.zsh".text = ''
    source $HOME/.config/zsh/fzf-tab/fzf-tab.plugin.zsh
    source ${pkgs.zsh-autosuggestions}/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
    source ${pkgs.zsh-fast-syntax-highlighting}/share/zsh/plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh
  '';

  home.file.".npmrc".text = ''
    prefix=${config.home.homeDirectory}/.local
  '';

  home.file.".vimrc".source = ./dotfiles/vimrc;
  programs.tmux = {
    enable = true;
    package = null;
    sensibleOnTop = true;
    plugins = with pkgs.tmuxPlugins; [
      sensible
      vim-tmux-navigator
      onedark-theme
    ];
    extraConfig = builtins.readFile ./dotfiles/tmux/tmux.conf;
  };
  programs.zellij = {
    enable = true;
    extraConfig = builtins.readFile ./dotfiles/zellij/config.kdl;
  };

  home.packages = with pkgs; [
    # --- 开发有关 ---
    rustc
    cargo
    rustfmt
    clippy
    rust-analyzer

    darklua

    nodejs_24
    typescript
    prettier
    eslint
    typescript-language-server

    nixd
    nixfmt

    go
    gopls
    air

    # --- 开发工具 ---
    just
    git-lfs
    nvimpager
    neovim
    tea

    packwiz

    aoc-cli

    # --- 其他工具 ---
    pandoc
    ripgrep
    fd
    btop
    fzf
    yazi
    starship
    imagemagick
  ];
}
