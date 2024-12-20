# List all the just commands
default:
    @just --list

# Generate CHANGELOG under `Unreleased`, starting from the previous release
changelog:
    cz ch --start-rev $(git describe --tags --abbrev=0 HEAD^) --incremental

# Run example/simple
ex-simple:
    cd ./example/simple && nix run . --override-input services-flake ../..

# Run example/llm
ex-llm:
    cd ./example/llm && nix run . --override-input services-flake ../..

# Run example/share-services
ex-share-services:
    cd ./example/share-services/pgweb && \
        nix run . \
            --override-input services-flake ../../.. \
            --override-input northwind ../northwind \

# Auto-format the project tree
fmt:
    treefmt

# Run native tests for all the services
test-all:
    nix flake check test/ --override-input services-flake . -L

# `nix flake check` doesn't support individual checks: https://github.com/NixOS/nix/issues/8881

# Run native test for a specific service
test service:
    nix build ./test#checks.$(nix eval --impure --expr "builtins.currentSystem").{{ service }} --override-input services-flake . -L

# Run doc server with hot-reload
doc:
    cd ./doc && nix run

# Build docs static website (this runs linkcheck automatically)
doc-static:
    nix build ./doc

clean-data:
    rm -rf test/.data

clean-logs:
    rm -rf test/.logs

clean: clean-data clean-logs

# Run service whose configuration is defined in `<service>_test.nix`
run service:
    cd test && nix run .#{{ service }} --override-input services-flake ../
