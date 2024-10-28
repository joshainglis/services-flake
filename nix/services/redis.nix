# Based on https://github.com/cachix/devenv/blob/main/src/modules/services/redis.nix
{ pkgs, lib, name, config, ... }:
let
  inherit (lib) types;
in
{
  options = {
    package = lib.mkPackageOption pkgs "redis" { };

    bind = lib.mkOption {
      type = types.nullOr types.str;
      default = "127.0.0.1";
      description = ''
        The IP interface to bind to.
        `null` means "all interfaces".
      '';
      example = "127.0.0.1";
    };

    port = lib.mkOption {
      type = types.port;
      default = 6379;
      description = ''
        The TCP port to accept connections.

        If port is set to `0`, redis will not listen on a TCP socket.
      '';
      apply = v:
        lib.warnIf ((config.unixSocket != null) && (v != 0)) ''
          `${name}` is listening on both the TCP port and Unix socket, set `port = 0;` to listen on only the Unix socket
        ''
          v;
    };

    unixSocket = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        The path to the socket to bind to.

        If a relative path is used, it will be relative to `dataDir`.
      '';
    };

    unixSocketPerm = lib.mkOption {
      type = types.int;
      default = 660;
      description = "Change permissions for the socket";
      example = 600;
    };

    logLevel = lib.mkOption {
      type = types.enum [ "debug" "verbose" "notice" "warning" "nothing" ];
      default = "notice";
      description = "The log level for redis";
    };

    extraConfig = lib.mkOption {
      type = types.lines;
      default = "";
      description = "Additional text to be appended to `redis.conf`.";
    };
  };

  config = {
    outputs = {
      settings = {
        processes = {
          "${name}" =
            let
              transformedSocketPath =
                if (config.unixSocket != null) then
                  if (lib.hasPrefix "/" config.unixSocket) then
                  # Already absolute path
                    config.unixSocket
                  else if (lib.hasPrefix "./" config.unixSocket) then
                  # Relative path starting with ./
                    "${config.dataDir}/${lib.removePrefix "./" config.unixSocket}"
                  else
                  # Relative path without ./
                    "${config.dataDir}/${config.unixSocket}"
                else
                  null;

              startScript = pkgs.writeShellApplication {
                name = "start-redis";
                runtimeInputs = [ pkgs.coreutils config.package ];
                text = ''
                  set -euo pipefail

                  export REDISDATADIR="${config.dataDir}/data"
                  mkdir -p "$REDISDATADIR"
                  DATADIR="$(readlink -f "$REDISDATADIR")"

                  # Create runtime dir for config
                  RUNTIME_DIR="${config.dataDir}/run"
                  mkdir -p "$RUNTIME_DIR"

                  ${lib.optionalString (transformedSocketPath != null) ''
                  SOCKET_DIR="$(dirname ${transformedSocketPath})"
                  mkdir -p "$SOCKET_DIR"
                  ''}

                  # Create config file
                  cat > "$RUNTIME_DIR/redis.conf" << EOF
                  port ${toString config.port}
                  ${lib.optionalString (config.bind != null) "bind ${config.bind}"}
                  ${lib.optionalString (config.unixSocket != null) "unixsocket $(readlink -f ${transformedSocketPath})"}
                  ${lib.optionalString (config.unixSocket != null) "unixsocketperm ${builtins.toString config.unixSocketPerm}"}
                  loglevel ${config.logLevel}
                  ${config.extraConfig}
                  EOF

                  exec redis-server "$RUNTIME_DIR/redis.conf" --dir "$DATADIR"
                '';
              };
            in
            {
              command = startScript;

              readiness_probe =
                {
                  exec.command =
                    if (transformedSocketPath != null && config.port == 0) then
                      ''${config.package}/bin/redis-cli -s "$(readlink -f ${transformedSocketPath})" ping''
                    else
                      "${config.package}/bin/redis-cli -p ${toString config.port} ping";
                };
            };
        };
      };
    };
  };
}
