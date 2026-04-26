{
  description = "hello world application using uv2nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-utils.url = "github:numtide/flake-utils";
    nix-oci = {
      url = "github:dauliac/nix-oci";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.follows = "treefmt-nix";
      inputs.flake-parts.follows = "flake-parts";
    };

    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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
    inputs@{
      flake-parts,
      flake-utils,
      self,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.nix-oci.flakeModule
      ];
      oci = {
        enabled = true;
        cve.grype.enabled = true;
        cve.trivy.enabled = true;
        sbom.syft.enabled = true;
        test.dive.enabled = true;
      };
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        # "aarch64-darwin"
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
          python = pkgs.python314;

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
            (pkgs.callPackage inputs.pyproject-nix.build.packages {
              inherit python;
            }).overrideScope
              (
                inputs.nixpkgs.lib.composeManyExtensions [
                  inputs.pyproject-build-systems.overlays.wheel
                  uvLockedOverlay
                ]
              );

          addMeta =
            drv:
            drv.overrideAttrs (old: {
              passthru = inputs.nixpkgs.lib.recursiveUpdate (old.passthru or { }) {
                inherit (pythonSet.testing.passthru) tests;
              };

              meta = (old.meta or { }) // {
                mainProgram = "fastapi";
                description = "hello fastapi";
              };
              version = "0.1.0";
            });
        in
        {
          devShells =
            let
              editablePythonSet = pythonSet.overrideScope editableOverlay;
              virtualenv = addMeta (pythonSet.mkVirtualEnv "hello-dev-env" workspace.deps.all);
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
            env = addMeta (pythonSet.mkVirtualEnv "hello-env" workspace.deps.default);
            default = self'.packages.env;
            mypy = pythonSet.mkVirtualEnv "mypy" workspace.deps.all;
            # need nix2container's skopeo for the `nix` datastore when messing
            # with the nix-oci stuff below, it's not used for the
            # streamLayeredImage because that outputs a script
            skopeo = inputs'.nix2container.packages.skopeo-nix2container;
            # nix run ".#push"
            # basically, i think nix-oci is unfinished, and i really don't like
            # how it layers and i can't put in the labels i want (those options
            # that would get passed into nix2container don't expose that field
            # currently)
            # also, need to figure out how to get to the mkOCIScript section
            # still, is that a package? something else?
            # if i were doing this, here's how i'd do it
            # 1. build image, with all the opencontainers labels/annotations
            # 2. optional multiarch merge step - do we sign just the multiarch
            # manifest, or the components as well? what about vuln scans?
            # 3. image attestation sign - is there a way to make this versatile with github
            # vs cosign, or do we just leave this step open to implementation?
            # 4. trivy sbom
            # 5. sbom sign
            # 6. vuln scan
            # 7. vuln scan sign - this bit integrates with cluster kyverno
            # policies that look for recent vuln scans
            docker = pkgs.dockerTools.streamLayeredImage {
              name = "hello";
              contents = [
                self'.packages.env
                pkgs.coreutils
                pkgs.dockerTools.binSh
              ];
              config = {
                # TODO add opencontainer labels/annotations
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
            default = self'.apps.fastapi;
            fastapi = {
              type = "app";
              program = "${self'.packages.env}/bin/fastapi";
            };
            # TODO tasks to still make as apps with inlined shell scripts:
            # * multiarch merge
            # * image sign provenance
            # * syft sbom
            # * sign sbom
            # * trivy scan
            # * sign trivy scan
            #
            # the overall goal here is that the CI script just calls the various
            # nix apps in this repo
            #
            # the alternative here is a justfile inside a devshell, but i want
            # to see how far i can take this design and how far it can go until
            # it breaks
            push-multiarch = flake-utils.lib.mkApp {
              drv = pkgs.writeShellApplication {
                name = "skopeo-push-multiarch";
                runtimeInputs = [
                  pkgs.git
                ];
                text = ''
                  GIT_REV=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
                  export TAG="tmp-${system}-$GIT_REV"
                  ${self'.apps.push.program}
                '';
              };
            };
            push = flake-utils.lib.mkApp {
              # writeShellApplication lets you inline shell scripts with their
              # own dependencies defined on its $PATH
              # also you get shellcheck automatically during the checkPhase
              drv = pkgs.writeShellApplication {
                name = "skopeo-push";
                runtimeInputs = [
                  pkgs.gzip
                  pkgs.skopeo
                  pkgs.git
                ];
                # notes:
                # the docker outPath is not a "real" package, the result of the
                # derivation is a shell script that calls the "stream docker
                # image" python script, which we then gzip via stdin, and then feed into skopeo
                # via stdin
                # TODO parameterize the image tag and repo name, so we can get
                # this in its own flake
                # TODO parameterize registry name as well for minikube
                # REGISTRY=ghcr.io/voidlily nix run ".#push"
                # ^^ can also specify TAG when able
                # this is extensible with like, TAG=tmp-${system}-amd64-$(git rev-parse ...)
                text = ''
                  GIT_REV=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
                  REGISTRY="''${REGISTRY:-localhost:5000}"
                  IMAGE=hello-nix-uv-py
                  TAG="''${TAG:-$GIT_REV}"
                  DEST="docker://$REGISTRY/$IMAGE:$TAG"
                  ${self'.packages.docker.outPath} | \
                  gzip --fast | \
                  skopeo copy \
                  docker-archive:/dev/stdin \
                  "''${DEST:-docker://localhost:5000/hello-nix-uv-py:test}"
                  # docker://ghcr.io/voidlily/hello-nix-uv-py:test
                '';
              };
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

          # this requires manual invocation to push due to multiarch being shite
          # nix build ".#oci-hello"
          # nix run ".#skopeo" copy nix:result docker://ghcr.io/voidlily/hello-nix-uv-py:$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
          # scripts inside the repo are a little brittle
          # they also don't let me pass the opencontainers annotations/labels in yet
          # nix-oci is also very opinionated about its layers
          oci.containers.hello = {
            package = self'.packages.env;
            multiArch.enabled = true;
            push = true;
            registry = "ghcr.io";
            name = "voidlily/hello-nix-uv-py";
            entrypoint = [
              "fastapi"
              "run"
              "-e"
              "hello.main:app"
            ];
          };

          oci.debug = {
            enabled = true;
            entrypoint.enabled = true;
            packages = with pkgs; [
              coreutils
              bash
              curl
            ];
          };
        };
    };
}
