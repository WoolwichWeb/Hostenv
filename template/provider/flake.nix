{
  description = "Hostenv provider template";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    hostenv = {
      url = "gitlab:woolwichweb/hostenv";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.phps.follows = "phps";
    };
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    phps = {
      url = "gitlab:woolwichweb/nix-phps-lts";
    };

    # Enter each project as a separate input using this template:
    # organisation__project = {
    #   url = "git:some-git-host/repo?dir=.hostenv&ref=main";
    #   # ^ If hostenv's flake.nix is in a different directory, or the root,
    #   #   change 'dir' accordingly.
    #   #   To change which branch contains the specification of a project's
    #   #   environments update 'ref'.

    #   inputs.nixpkgs.follows = "nixpkgs";
    #   inputs.hostenv.follows = "hostenv";
    #   inputs.flake-parts.follows = "flake-parts";
    # };
    # Note: hostenv uses the double-underscore (__) to determine which inputs
    # are hostenv projects and which are just standard inputs, like 'nixpkgs'.

  };

  outputs = inputs@{ flake-parts, hostenv, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      imports = [
        hostenv.flakeModules.provider
      ];

      provider = {
        hostenvHostname = "hosting.example.com";
        deployPublicKeys = [ "ssh-ed25519 AAAA..." ];
        nodeSystems.node-a = "x86_64-linux";
        nodeFor.default = "node-a";
        # Override by environment type when using more than one node:
        # nodeFor.production = "node-b";
        # nodeSystems.node-b = "aarch64-linux";
        #
        # When draining a node, remove it from nodeFor but keep it in
        # nodeSystems until cleanup completes:
        # nodeStatus.node-b = "retiring";

        # Add NixOS system-level configuration that's common to all servers here:
        # nodeModules = [ "nodes/common.nix" ];

        # Hostenv generates a new flake in `generated/flake.nix`, which
        # includes each project environment as a separate Flake input. These
        # options allow providers to tweak the generated flake's inputs:
        # generatedFlake = {
        #   inputs = {
        #     # extraInput = { url = "github:example/extra"; };
        #     # disko = {
        #     #   url = "github:nix-community/disko";
        #     #   inputs.nixpkgs.follows = "nixpkgs";
        #     # };
        #   };
        #   envInputs = {
        #     # follows = { nixpkgs = "parent/nixpkgs"; };
        #     # extra = env: { inputs = { sops-nix = { follows = "parent/sops-nix"; }; }; };
        #   };
        # };

        letsEncrypt.adminEmail = "admin@hosting.example.com";
        letsEncrypt.acceptTerms = true;
      };
    };
}
