{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-root.url = "github:srid/flake-root";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    pre-commit-hooks-nix = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nixpkgs-stable.follows = "nixpkgs";
      };
    };
    # CI will override `services-flake` to run checks on the latest source
    services-flake.url = "github:joshainglis/services-flake";
  };
  outputs = inputs@{ self, nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = nixpkgs.lib.systems.flakeExposed;
      imports = [
        inputs.flake-root.flakeModule
        inputs.treefmt-nix.flakeModule
        inputs.pre-commit-hooks-nix.flakeModule
        ./nix/pre-commit.nix
      ];
      perSystem = { pkgs, lib, config, ... }: {
        treefmt = {
          projectRoot = inputs.services-flake;
          projectRootFile = "flake.nix";
          # Even though pre-commit-hooks.nix checks it, let's have treefmt-nix
          # check as well until #238 is fully resolved.
          # flakeCheck = false; # pre-commit-hooks.nix checks this
          programs = {
            nixpkgs-fmt.enable = true;
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.just
            pkgs.nixd
            config.pre-commit.settings.tools.commitizen
            pkgs.process-compose
            (pkgs.python3.withPackages (ps: [ ps.psycopg ps.yoyo-migrations ]))
          ];
          inputsFrom = [
            config.treefmt.build.devShell
            config.pre-commit.devShell
            config.flake-root.devShell
          ];
          shellHook = ''
            echo
            echo "🍎🍎 Run 'just <recipe>' to get started"
            just
          '';
        };
      };
    };
}
