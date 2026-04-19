{
  description = "hello world application using uv2nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    flake-parts.url = "github:hercules-ci/flake-parts";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, self, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      perSystem =
        {
          config,
          self',
          inputs',
          pkgs,
          system,
          ...
        }:
        let
          pythonSet =
            let
              inherit (inputs'.nixpkgs) lib;
              python = pkgs.python3;
            in
            (pkgs.callPackage inputs'.pyproject-nix.build.packages {
              inherit python;
            }).overrideScope
              (
                lib.composeManyExtensions [
                  inputs.pyproject-build-systems.overlays.wheel
                  self'.overlay
                ]
              );
        in
        {
          devShells =
            let
              pythonSet = pythonSet.overrideScope self'.editableOverlay;
              virtualenv = pythonSet.mkVirtualEnv "hello-dev-env" self'.workspace.deps.all;
            in
            {
              default = pkgs.mkShell {
                packages = [
                  virtualenv
                  pkgs.uv
                ];
                env = {
                  UV_NO_SYNC = "1";
                  UV_PYTHON = pythonSet.python.interpreter;
                  UV_PYTHON_DOWNLOADS = "never";
                };
                shellHook = ''
                  unset PYTHONPATH
                  export REPO_ROOT=$(git rev-parse --show-toplevel)
                '';
              };
            };
        };
      flake =
        let
          inherit (inputs.nixpkgs) lib;
          forAllSystems = lib.genAttrs lib.systems.flakeExposed;

          workspace = inputs.uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

          overlay = workspace.mkPyprojectOverlay {
            sourcePreference = "wheel";
          };

          editableOverlay = workspace.mkEditablePyprojectOverlay {
            root = "$REPO_ROOT";
          };

          pythonSets = forAllSystems (
            system:
            let
              pkgs = inputs.nixpkgs.legacyPackages.${system};
              python = pkgs.python3;
            in
            (pkgs.callPackage inputs.pyproject-nix.build.packages {
              inherit python;
            }).overrideScope
              (
                lib.composeManyExtensions [
                  inputs.pyproject-build-systems.overlays.wheel
                  overlay
                ]
              )
          );

        in
        {
          devShells = forAllSystems (
            system:
            let
              pkgs = inputs.nixpkgs.legacyPackages.${system};
              pythonSet = pythonSets.${system}.overrideScope editableOverlay;
              virtualenv = pythonSet.mkVirtualEnv "hello-dev-env" workspace.deps.all;
            in
            {
              default = pkgs.mkShell {
                packages = [
                  virtualenv
                  pkgs.uv
                ];
                env = {
                  UV_NO_SYNC = "1";
                  UV_PYTHON = pythonSet.python.interpreter;
                  UV_PYTHON_DOWNLOADS = "never";
                };
                shellHook = ''
                  unset PYTHONPATH
                  export REPO_ROOT=$(git rev-parse --show-toplevel)
                '';
              };
            }
          );

          packages = forAllSystems (
            system:
            let
              pkgs = inputs.nixpkgs.legacyPackages.${system};
            in
            {
              env = pythonSets.${system}.mkVirtualEnv "hello-env" workspace.deps.default;
              mypy = pythonSets.${system}.mkVirtualEnv "mypy" workspace.deps.all;
              docker = pkgs.dockerTools.streamLayeredImage {
                name = "hello";
                contents = [
                  self.packages.${system}.env
                  pkgs.coreutils
                  pkgs.dockerTools.binSh
                ];
                config = {
                  exposedPorts = {
                    "8000/tcp" = { };
                  };
                  Cmd = [
                    "fastapi"
                    "run"
                    "-e"
                    "hello.main:app"
                  ];
                };
              };
            }
          );

          apps = forAllSystems (system: {
            default = {
              type = "app";
              program = "${self.packages.${system}.env}/bin/fastapi";
            };
          });

          formatter = forAllSystems (
            system:
            let
              pkgs = inputs.nixpkgs.legacyPackages.${system} // self.packages.${system};
              treefmtEval = inputs.treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
            in
            treefmtEval.config.build.wrapper
          );
          checks = forAllSystems (
            system:
            let
              pkgs = inputs.nixpkgs.legacyPackages.${system} // self.packages.${system};
              treefmtEval = inputs.treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
            in
            {
              formatting = treefmtEval.config.build.check self;
            }
          );

        };
    };
}
