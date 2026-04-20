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
      imports = [
        inputs.treefmt-nix.flakeModule
      ];
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
          python = pkgs.python3;

          workspace = inputs.uv2nix.lib.workspace.loadWorkspace {
            workspaceRoot = ./.;
          };

          uvLockedOverlay = workspace.mkPyprojectOverlay {
            sourcePreference = "wheel";
          };

          editableOverlay = workspace.mkEditablePyprojectOverlay {
            root = "$REPO_ROOT";
          };

          pythonSet =
            let
              inherit (inputs.nixpkgs) lib;
              python = pkgs.python3;
            in
            (pkgs.callPackage inputs.pyproject-nix.build.packages {
              inherit python;
            }).overrideScope
              (
                lib.composeManyExtensions [
                  inputs.pyproject-build-systems.overlays.wheel
                  uvLockedOverlay
                ]
              );

          projectAsPackage = pythonSet.hello;
        in
        {
          devShells =
            let
              editablePythonSet = pythonSet.overrideScope editableOverlay;
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
                  UV_PYTHON = editablePythonSet.python.interpreter;
                  UV_PYTHON_DOWNLOADS = "never";
                };
                shellHook = ''
                  unset PYTHONPATH
                  export REPO_ROOT=$(git rev-parse --show-toplevel)
                '';
              };
            };
          packages = {
            env = pythonSet.mkVirtualEnv "hello-env" workspace.deps.default;
            default = self'.packages.env;
            mypy = pythonSet.mkVirtualEnv "mypy" workspace.deps.all;
            docker = pkgs.dockerTools.streamLayeredImage {
              name = "hello";
              contents = [
                self'.packages.env
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
          };

          apps = {
            default = {
              type = "app";
              program = "${self'.packages.env}/bin/fastapi";
            };
          };

          treefmt = {
            programs = {
              mypy = {
                enable = true;
                package = self'.packages.mypy;
              };
              ruff-check.enable = true;
              ruff-format.enable = true;
            };
          };
        };
    };
}
