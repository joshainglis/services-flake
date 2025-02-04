# Based on https://github.com/cachix/devenv/blob/main/src/modules/services/postgres.nix
{ name
, config
, pkgs
, lib
, ...
}:
let
  inherit (lib) types;
in
{
  options = {
    package = lib.mkOption {
      type = types.package;
      description = "Which package of postgresql to use";
      default = pkgs.postgresql;
      defaultText = lib.literalExpression "pkgs.postgresql";
      apply = postgresPkg:
        if config.extensions != null
        then
          if builtins.hasAttr "withPackages" postgresPkg
          then postgresPkg.withPackages config.extensions
          else
            builtins.throw ''
              Cannot add extensions to the PostgreSQL package.
              `services.postgres.package` is missing the `withPackages` attribute. Did you already add extensions to the package?
            ''
        else postgresPkg;
    };

    extensions = lib.mkOption {
      type = with types; nullOr (functionTo (listOf package));
      default = null;
      example = lib.literalExpression ''
        extensions: [
          extensions.pg_cron
          extensions.postgis
          extensions.timescaledb
        ];
      '';
      description = ''
        Additional PostgreSQL extensions to install.

        The available extensions are:

        ${lib.concatLines (builtins.map (x: "- " + x) (builtins.attrNames pkgs.postgresql.pkgs))}
      '';
    };

    pgDataDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.dataDir}/pgdata";
      description = ''
        The directory where the PostgreSQL data is stored.
      '';
    };

    socketDir = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "The DB socket directory";
      defaultText = ''
        An empty value specifies not listening on any Unix-domain sockets, in which case only TCP/IP sockets can be used to connect to the server.
        See: https://www.postgresql.org/docs/current/runtime-config-connection.html#GUC-UNIX-SOCKET-DIRECTORIES
      '';
    };

    # Based on: https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNSTRING-URIS
    connectionURI = lib.mkOption {
      type = lib.types.functionTo lib.types.str;
      readOnly = true;
      default = { dbName, ... }: "postgres://${config.listen_addresses}:${builtins.toString config.port}/${dbName}";
      description = ''
        A function that accepts an attrset overriding the connection parameters
        and returns the [postgres connection URI](https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNSTRING-URIS)
      '';
    };

    yoyoPackage = lib.mkOption {
      type = types.package;
      default = pkgs.python3.withPackages (ps: [ ps.yoyo-migrations ps.psycopg ]);
      description = ''
        The yoyo-migrations package.
      '';
    };

    yoyoConnectionURI = lib.mkOption {
      type = lib.types.functionTo lib.types.str;
      readOnly = true;
      default =
        { dbName
        , driver
        , ...
        }: "postgresql+${driver}://${
        if config.socketDir != ""
        then ""
        else "${config.listen_addresses}:${builtins.toString config.port}"
      }/${dbName}${
        if config.socketDir != ""
        then "?host=${config.socketDir}&port=${config.port}"
        else ""
      }";
      description = ''
        A function that accepts an attrset overriding the connection parameters
        and returns the [postgres connection URI](https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNSTRING-URIS)
      '';
    };

    hbaConf =
      let
        hbaConfSubmodule = lib.types.submodule {
          options = {
            type = lib.mkOption { type = lib.types.str; };
            database = lib.mkOption { type = lib.types.str; };
            user = lib.mkOption { type = lib.types.str; };
            address = lib.mkOption { type = lib.types.str; };
            method = lib.mkOption { type = lib.types.str; };
          };
        };
      in
      lib.mkOption {
        type = lib.types.listOf hbaConfSubmodule;
        default = [ ];
        description = ''
          A list of objects that represent the entries in the pg_hba.conf file.

          Each object has sub-options for type, database, user, address, and method.

          See the official PostgreSQL documentation for more information:
          https://www.postgresql.org/docs/current/auth-pg-hba-conf.html
        '';
        example = [
          {
            type = "local";
            database = "all";
            user = "postgres";
            address = "";
            method = "md5";
          }
          {
            type = "host";
            database = "all";
            user = "all";
            address = "0.0.0.0/0";
            method = "md5";
          }
        ];
      };
    hbaConfFile =
      let
        # Default pg_hba.conf entries
        defaultHbaConf = [
          {
            type = "local";
            database = "all";
            user = "all";
            address = "";
            method = "trust";
          }
          {
            type = "host";
            database = "all";
            user = "all";
            address = "127.0.0.1/32";
            method = "trust";
          }
          {
            type = "host";
            database = "all";
            user = "all";
            address = "::1/128";
            method = "trust";
          }
          {
            type = "local";
            database = "replication";
            user = "all";
            address = "";
            method = "trust";
          }
          {
            type = "host";
            database = "replication";
            user = "all";
            address = "127.0.0.1/32";
            method = "trust";
          }
          {
            type = "host";
            database = "replication";
            user = "all";
            address = "::1/128";
            method = "trust";
          }
        ];

        # Merge the default pg_hba.conf entries with the user-defined entries
        hbaConf = defaultHbaConf ++ config.hbaConf;

        # Convert the pgHbaConf array to a string
        hbaConfString = ''
          # Generated by Nix
          ${"# TYPE\tDATABASE\tUSER\tADDRESS\tMETHOD\n"}
          ${lib.concatMapStrings (cnf: "  ${cnf.type}\t${cnf.database}\t${cnf.user}\t${cnf.address}\t${cnf.method}\n") hbaConf}
        '';
      in
      lib.mkOption {
        type = lib.types.package;
        internal = true;
        readOnly = true;
        description = "The `pg_hba.conf` file.";
        default = pkgs.writeText "pg_hba.conf" hbaConfString;
      };

    listen_addresses = lib.mkOption {
      type = lib.types.str;
      description = "Listen address";
      default = "127.0.0.1";
      example = "127.0.0.1";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5432;
      description = ''
        The TCP port to accept connections.
      '';
    };

    superuser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of superuser.
        null defaults to $USER
      '';
    };

    createDatabase = lib.mkOption {
      type = types.bool;
      default = true;
      description = ''
        Create a database named like current user on startup. Only applies when initialDatabases is an empty list.
      '';
    };

    initdbArgs = lib.mkOption {
      type = types.listOf types.lines;
      default = [ "--locale=C" "--encoding=UTF8" ];
      example = [ "--data-checksums" "--allow-group-access" ];
      description = ''
        Additional arguments passed to `initdb` during data dir
        initialisation.
      '';
    };

    defaultSettings = lib.mkOption {
      type = with lib.types; attrsOf (oneOf [ bool float int str ]);
      internal = true;
      readOnly = true;
      description = ''
        Default configuration for `postgresql.conf`. `settings` can override these values.
      '';
      default = {
        listen_addresses = config.listen_addresses;
        port = config.port;
        unix_socket_directories = config.socketDir;
        hba_file = "${config.hbaConfFile}";
      };
    };

    settings = lib.mkOption {
      type = with lib.types; attrsOf (oneOf [ bool float int str ]);
      default = { };
      description = ''
        PostgreSQL configuration. Refer to
        <https://www.postgresql.org/docs/11/config-setting.html#CONFIG-SETTING-CONFIGURATION-FILE>
        for an overview of `postgresql.conf`.

        String values will automatically be enclosed in single quotes. Single quotes will be
        escaped with two single quotes as described by the upstream documentation linked above.
      '';
      default = {
        listen_addresses = config.listen_addresses;
        port = config.port;
        unix_socket_directories = lib.mkDefault config.socketDir;
        hba_file = "${config.hbaConfFile}";
      };
      example = lib.literalExpression ''
        {
          log_connections = true;
          log_statement = "all";
          logging_collector = true
          log_disconnections = true
          log_destination = lib.mkForce "syslog";
        }
      '';
    };
    restoreFromDump = lib.mkOption {
      type = types.nullOr (types.submodule {
        options = {
          file = lib.mkOption {
            type = types.oneOf [ types.path types.str ];
            description = "Path to the SQL dump file (from pg_dumpall)";
          };
          stopOnError = lib.mkOption {
            type = types.bool;
            default = true;
            description = "Stop if any errors are encountered when restoring the dump";
          };
        };
      });
      default = null;
      description = "Restore database from a pg_dumpall SQL file";
    };

    initialDatabases = lib.mkOption {
      type =
        types.listOf
          (types.submodule {
            options = {
              name = lib.mkOption {
                type = types.str;
                description = ''
                  The name of the database to create.
                '';
              };
              schemas = lib.mkOption {
                type = types.nullOr (types.listOf (types.oneOf [ types.path types.str ]));
                default = null;
                description = ''
                  The initial list of schemas for the database; if null (the default),
                  an empty database is created.

                  If path is a directory, use `*.sql` files in name order.
                '';
              };
              stopOnError = lib.mkOption {
                type = types.bool;
                default = true;
                description = "Stop if any errors are encountered when aplying .sql files";
              };
              yoyoMigrations =
                lib.mkOption
                  {
                    type =
                      types.nullOr
                        (types.submodule {
                          options = {
                            scripts_dirs = lib.mkOption {
                              type = types.nullOr (types.listOf (types.oneOf [ types.path types.str ]));
                              description = ''
                                The paths to the yoyo migrations scripts directories.
                              '';
                            };
                            verbosity = lib.mkOption {
                              type = types.int;
                              default = 1;
                              description = ''
                                The verbosity level of the yoyo migrations. can be 0, 1, 2, 3.
                              '';
                            };
                          };
                        });
                    default = null;
                    description = ''
                      The path to the yoyo migrations scripts directories.
                    '';
                  };
              postApplySchemas = lib.mkOption {
                type = types.nullOr (types.listOf (types.oneOf [ types.path types.str ]));
                default = [ ];
                description = ''
                  The list of files to run after applying the yoyo migrations.
                '';
              };
            };
          });
      default = [ ];
      description = ''
        List of database names and their initial schemas that should be used to create databases on the first startup
        of Postgres. The schema attribute is optional: If not specified, an empty database is created.
      '';
      example = lib.literalExpression ''
        [
          {
            name = "foodatabase";
            schemas = [ ./fooschemas ./bar.sql ];
            yoyoMigrations = [ ./migrations/scripts ./migrations/scripts/archived ];
          }
          { name = "bardatabase"; }
        ]
      '';
    };

    initialScript = lib.mkOption {
      type = types.submodule ({ config, ... }: {
        options = {
          before = lib.mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              SQL commands to run before the database initialization.
            '';
            example = lib.literalExpression ''
              CREATE USER postgres SUPERUSER;
              CREATE USER bar;
            '';
          };
          after = lib.mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              SQL commands to run after the database initialization.
            '';
            example = lib.literalExpression ''
              CREATE TABLE users (
                id SERIAL PRIMARY KEY,
                name VARCHAR(50) NOT NULL,
                email VARCHAR(50) NOT NULL UNIQUE
              );
            '';
          };
        };
      });
      default = {
        before = null;
        after = null;
      };
      description = ''
        Initial SQL commands to run during database initialization. This can be multiple
        SQL expressions separated by a semi-colon.
      '';
    };
  };
  config = {
    outputs = {
      settings = {
        processes = {
          # DB initialization
          "${name}-init" =
            let
              setupScript = import ./setup-script.nix {
                inherit config pkgs lib;
              };
            in
            {
              command = setupScript;
              log_location = "${config.logDir}/${name}-init.log";
              availability.restart = "exit_on_failure";
              shutdown = {
                signal = 15;
                parent_only = false;
              };
            };

          # DB process
          ${name} =
            let
              startScript = pkgs.writeShellApplication {
                name = "start-postgres";
                runtimeInputs = [ config.package pkgs.coreutils config.yoyoPackage ];
                text = ''
                  set -xeuo pipefail
                  PGDATA=$(readlink -f "${config.pgDataDir}")
                  export PGDATA
                  ${
                    if config.socketDir != ""
                    then ''
                      PGSOCKETDIR=$(readlink -f "${config.socketDir}")
                      ${lib.getExe' config.package "postgres"} -k "$PGSOCKETDIR"
                    ''
                    else ''
                      ${lib.getExe' config.package "postgres"}
                    ''
                  }
                '';
              };
              pg_isreadyArgs =
                [
                  (
                    if config.socketDir != ""
                    then "-h $(readlink -f \"${config.socketDir}\")"
                    else "-h ${config.listen_addresses}"
                  )
                  "-p ${toString config.port}"
                  "-d template1"
                ]
                ++ (lib.optional (config.superuser != null) "-U ${config.superuser}");
            in
            {
              command = startScript;
              is_daemon = false;
              shutdown = { signal = 2; timeout_seconds = 5; parent_only = false; };
              readiness_probe.exec.command = "${lib.getExe' config.package "pg_isready"} ${lib.concatStringsSep " " pg_isreadyArgs}";
              liveness_probe.exec.command = "${lib.getExe' config.package "pg_isready"} ${lib.concatStringsSep " " pg_isreadyArgs}";
              availability.restart = "on_failure";
              depends_on."${name}-init".condition = "process_completed_successfully";
            };
        };
      };
    };
  };
}
