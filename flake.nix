{
  description = "Gemini-FastAPI: Web-based Gemini models wrapped into an OpenAI-compatible API";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

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
    {
      self,
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };

      editableOverlay = workspace.mkEditablePyprojectOverlay {
        root = "$REPO_ROOT";
      };

      source = lib.cleanSourceWith {
        src = lib.cleanSource ./.;
        filter =
          path: type:
          !(lib.any (dir: lib.hasInfix dir path) [
            ".venv"
            "__pycache__"
          ]);
      };

      pythonSets = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          python = pkgs.python314;
        in
        (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        }).overrideScope
          (
            lib.composeManyExtensions [
              pyproject-build-systems.overlays.wheel
              overlay
              pyprojectOverrides
            ]
          )
      );

      pyprojectOverrides = final: prev: {
        gemini-webapi = prev.gemini-webapi.overrideAttrs (old: {
          nativeBuildInputs =
            old.nativeBuildInputs or [ ]
            ++ final.resolveBuildSystem {
              setuptools = [ ];
            };
          postPatch = (old.postPatch or "") + ''
            substituteInPlace pyproject.toml \
              --replace-fail 'include = ["gemini_webapi"]' 'include = ["gemini_webapi*"]'
          '';
        });
      };
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pythonSet = pythonSets.${system}.overrideScope editableOverlay;
          virtualenv = pythonSet.mkVirtualEnv "gemini-fastapi-dev-env" workspace.deps.all;
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
          pkgs = nixpkgs.legacyPackages.${system};
          venv = pythonSets.${system}.mkVirtualEnv "gemini-fastapi-env" workspace.deps.default;
        in
        rec {
          gemini-fastapi = pkgs.stdenvNoCC.mkDerivation {
            pname = "gemini-fastapi";
            version = "1.0.0";

            src = source;
            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              runHook preInstall

              mkdir -p $out/share/gemini-fastapi
              cp -r app run.py config $out/share/gemini-fastapi/

              mkdir -p $out/bin
              makeWrapper ${venv}/bin/python $out/bin/gemini-fastapi \
                --add-flags "$out/share/gemini-fastapi/run.py" \
                --set-default CONFIG_PATH $out/share/gemini-fastapi/config/config.yaml

              runHook postInstall
            '';
          };

          default = gemini-fastapi;
        }
      );

      apps = forAllSystems (
        system:
        let
          gemini-fastapi = self.packages.${system}.gemini-fastapi;
        in
        {
          default = {
            type = "app";
            program = "${gemini-fastapi}/bin/gemini-fastapi";
          };
          gemini-fastapi = {
            type = "app";
            program = "${gemini-fastapi}/bin/gemini-fastapi";
          };
        }
      );
    };
}
