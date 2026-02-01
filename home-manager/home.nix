# Home Manager Configuration for Barleta Homelab
# jeff@g913 (Ubuntu Server + Nix)

{ config, pkgs, ... }:

{
  # User identity
  home.username = "jeff";
  home.homeDirectory = "/home/jeff";
  home.stateVersion = "24.11";

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  # ============================================
  # PACKAGES
  # ============================================
  home.packages = with pkgs; [
    # Kubernetes tooling
    kubectl
    kubernetes-helm
    k9s
    stern           # Multi-pod log tailing
    kubectx         # Context/namespace switcher
    kustomize
    argocd          # ArgoCD CLI
    
    # Container tools
    docker-compose
    dive            # Docker image explorer
    
    # System utilities
    htop
    btop
    ripgrep
    fd
    fzf
    jq
    yq
    tree
    
    # Network tools
    curl
    wget
    iperf3
    nmap
    
    # Git & development
    git
    gh              # GitHub CLI
    lazygit
    
    # Hardware monitoring
    pciutils
    usbutils
    lm_sensors
    nvtopPackages.nvidia
  ];

  # ============================================
  # GIT
  # ============================================
  programs.git = {
    enable = true;
    userName = "Jeff Louis-Ma";
    userEmail = "jefflouisma@me.com";
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
    };
  };

  # ============================================
  # SHELL (ZSH)
  # ============================================
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    
    shellAliases = {
      # Kubernetes
      k = "kubectl";
      kgp = "kubectl get pods -A";
      kgs = "kubectl get svc -A";
      kgn = "kubectl get nodes";
      kns = "kubens";
      kctx = "kubectx";
      
      # Docker
      d = "docker";
      dc = "docker-compose";
      
      # System
      ll = "ls -lah";
      ".." = "cd ..";
      "..." = "cd ../..";
      
      # Git
      gs = "git status";
      gp = "git pull";
      gc = "git commit";
      gco = "git checkout";
    };

    initExtra = ''
      # Kubernetes context in prompt
      export KUBECONFIG=~/.kube/config

      # Editor
      export EDITOR=nvim
      export VISUAL=nvim
    '';
  };

  # ============================================
  # STARSHIP PROMPT
  # ============================================
  programs.starship = {
    enable = true;
    settings = {
      add_newline = true;
      
      kubernetes = {
        disabled = false;
        format = "[$symbol$context( \\($namespace\\))]($style) ";
      };
      
      git_branch = {
        symbol = " ";
      };
      
      directory = {
        truncation_length = 3;
        truncate_to_repo = true;
      };
    };
  };

  # ============================================
  # TMUX
  # ============================================
  programs.tmux = {
    enable = true;
    terminal = "screen-256color";
    historyLimit = 10000;
    mouse = true;
    keyMode = "vi";
    
    extraConfig = ''
      # Split panes with | and -
      bind | split-window -h
      bind - split-window -v
      
      # Status bar
      set -g status-right '#[fg=green]#H'
    '';
  };

  # ============================================
  # NEOVIM
  # ============================================
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    
    extraConfig = ''
      set number
      set relativenumber
      set expandtab
      set shiftwidth=2
      set tabstop=2
      set mouse=a
      set clipboard=unnamedplus
    '';
  };

  # ============================================
  # FZF (Fuzzy Finder)
  # ============================================
  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  # ============================================
  # DIRENV (Auto-load .envrc)
  # ============================================
  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };
}
