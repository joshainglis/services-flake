{ config
, pkgs
, lib
,
}:
let
  restoreFromDump = lib.optionalString (config.restoreFromDump != null) ''
    echo "Restoring database from dump file: ${config.restoreFromDump.file}"
    ${lib.getExe' pkgs.gawk "awk"} 'NF' "${config.restoreFromDump.file}" | ERROR_STOP=${ if config.restoreFromDump.stopOnError then "1" else "0" } psql_with_args -d postgres
  '';
  runSchemas = db: schema: ''
    echo "Applying database schema on ${db.name}"
    if [ -f "${schema}" ]
    then
      echo "Running file ${schema}"
      ${lib.getExe' pkgs.gawk "awk"} 'NF' "${schema}" | ERROR_STOP=${ if db.stopOnError then "1" else "0" } psql_with_args -d ${db.name}
    elif [ -d "${schema}" ]
    then
      # Read sql files in version order. Apply one file
      # at a time to handle files where the last statement
      # doesn't end in a ;.
      find "${schema}"/*.sql | while read -r f ; do
        echo "Applying sql file: $f"
        ${lib.getExe' pkgs.gawk "awk"} 'NF' "$f" | ERROR_STOP=${ if db.stopOnError then "1" else "0" } psql_with_args -d ${db.name}
      done
    else
      echo "ERROR: Could not determine how to apply schema with ${schema}"
      exit 1
    fi
  '';
  setupInitialDatabases =
    if config.initialDatabases != [ ]
    then
      (lib.concatMapStrings
        (db: ''
          echo "Checking presence of database: ${db.name}"
          # Create initial databases
          dbAlreadyExists=$(
            echo "SELECT 1 as exists FROM pg_database WHERE datname = '${db.name}';" | \
            psql_with_args -d postgres | \
            ${lib.getExe' pkgs.gnugrep "grep"} -c 'exists = "1"' || true
          )
          echo "$dbAlreadyExists"
          if [ 1 -ne "$dbAlreadyExists" ]; then
            echo "Creating database: ${db.name}"
            echo 'create database "${db.name}";' | psql_with_args -d postgres
            ${lib.optionalString (db.schemas != null)
            (lib.concatMapStrings (schema: runSchemas db schema) db.schemas)}
          fi
        '')
        config.initialDatabases)
    else lib.optionalString config.createDatabase ''echo "CREATE DATABASE ''${USER:-$(id -nu)};" | psql_with_args -d postgres '';

  runPostApply =
    if config.initialDatabases != [ ]
    then
      (lib.concatMapStrings
        (db: ''
          ${lib.optionalString (db.postApplySchemas != null)
            (lib.concatMapStrings (schema: runSchemas db schema) db.postApplySchemas)}
        '')
        config.initialDatabases)
    else "";

  runYoyoMigrations =
    if config.initialDatabases != [ ]
    then
      (lib.concatMapStrings
        (
          db:
          if ((db.yoyoMigrations != null) && (db.yoyoMigrations.scripts_dirs != [ ]))
          then
            let
              verbosityFlag =
                if db.yoyoMigrations.verbosity < 1
                then ""
                else "-" + lib.concatStrings (lib.genList (x: "v") (lib.min 3 db.yoyoMigrations.verbosity));

              scriptsDirs = lib.concatStringsSep " " db.yoyoMigrations.scripts_dirs;
            in
            ''
              echo "Applying yoyo migrations"
              ${lib.getExe' config.yoyoPackage "yoyo"} apply ${verbosityFlag} --batch --no-config-file --database "$(db_uri ${db.name})" ${scriptsDirs}
            ''
          else ""
        )
        config.initialDatabases)
    else "";

  runInitialScript =
    let
      scriptCmd = sqlScript: ''
        echo "${sqlScript}" | psql_with_args -d postgres
      '';
    in
    {
      before = with config.initialScript;
        lib.optionalString (before != null) (scriptCmd before);
      after = with config.initialScript;
        lib.optionalString (after != null) (scriptCmd after);
    };
  toStr = value:
    if true == value
    then "yes"
    else if false == value
    then "no"
    else if lib.isString value
    then "'${lib.replaceStrings ["'"] ["''"] value}'"
    else toString value;
  configFile =
    pkgs.writeText "postgresql.conf" (lib.concatStringsSep "\n"
      (lib.mapAttrsToList (n: v: "${n} = ${toStr v}") (config.defaultSettings // config.settings)));

  initdbArgs =
    config.initdbArgs
    ++ (lib.optionals (config.superuser != null) [ "-U" config.superuser ])
    ++ [ "-D" config.pgDataDir ];

  anyYoyoMigrations = lib.any (db: db.yoyoMigrations != null && db.yoyoMigrations.scripts_dirs != [ ]) config.initialDatabases;
in
(pkgs.writeShellApplication {
  name = "setup-postgres";
  runtimeInputs = with pkgs; [ config.package coreutils gnugrep gawk findutils (python3.withPackages (ps: [ ps.psycopg ps.yoyo-migrations ])) ];
  text = ''
    set -e
    set -o pipefail
    set -x
    # Execute the `psql` command with default arguments
    function psql_with_args() {
        local error_stop=''${ERROR_STOP:-1}  # Default to 1 if not set
        ${lib.getExe' config.package "psql"} ${lib.optionalString (config.superuser != null) "-U ${config.superuser}"} -v "ON_ERROR_STOP=$error_stop" "$@"
    }
    function db_uri() {
      echo "postgresql+psycopg://${lib.optionalString (config.superuser != null) "${config.superuser}"}@/$1?host=$PGHOST&port=$PGPORT"
    }

    function cleanup() {
        local exit_code=$?
        echo "Cleaning up..."
        if [[ -d "$PGHOST" ]]; then
            # Try to stop postgres if it's running
            ${lib.getExe' config.package "pg_ctl"} -D "$PGDATA" -m immediate -w stop || true

            rm -rf "$PGHOST"
        fi
        exit $exit_code
    }

    trap cleanup ERR EXIT

    # Setup postgres ENVs
    export PGDATA="${config.pgDataDir}"
    export PGPORT="${toString config.port}"
    POSTGRES_RUN_INITIAL_SCRIPT="false"
    POSTGRES_RUN_YOYO_MIGRATIONS="${
      if anyYoyoMigrations
      then "true"
      else "false"
    }"

    if [[ ! -d "$PGDATA" ]]; then
      ${lib.getExe' config.package "initdb"} ${lib.concatStringsSep " " initdbArgs}
      POSTGRES_RUN_INITIAL_SCRIPT="true"
      echo
      echo "PostgreSQL initdb process complete."
      echo
    fi

    # Setup config
    echo "Setting up postgresql.conf"
    cp ${configFile} "$PGDATA/postgresql.conf"
    # Create socketDir if it doesn't exist and it is not empty
    ${lib.optionalString (config.socketDir != "") ''
      if [ ! -d "${config.socketDir}" ]; then
        echo "Creating socket directory"
        mkdir -p "${config.socketDir}"
      fi
    ''}

    if [[ "$POSTGRES_RUN_INITIAL_SCRIPT" = "true" ]] || [[ "$POSTGRES_RUN_YOYO_MIGRATIONS" = "true" ]]; then
      echo
      echo "PostgreSQL is setting up the initial database."
      echo
      ${
      if config.socketDir != ""
      then ''
        PGHOST=$(mktemp -d "$(readlink -f "${config.socketDir}")/pg-init-XXXXXX")
      ''
      else ''
        PGHOST=$(mktemp -d /tmp/pg-init-XXXXXX)
      ''
    }
      export PGHOST

      ${lib.getExe' config.package "pg_ctl"} -D "$PGDATA" -w start -o "-c unix_socket_directories=$PGHOST -c listen_addresses= -p ${toString config.port}"
      if [[ "$POSTGRES_RUN_INITIAL_SCRIPT" = "true" ]]; then
      ${runInitialScript.before}
      ${restoreFromDump}
      ${setupInitialDatabases}
      ${runInitialScript.after}
      fi

      ${runYoyoMigrations}
      ${runPostApply}

      ${lib.getExe' config.package "pg_ctl"} -D "$PGDATA" -m fast -w stop
    else
      echo
      echo "PostgreSQL database directory appears to contain a database; Skipping initialization"
      echo
    fi
    unset POSTGRES_RUN_INITIAL_SCRIPT
  '';
})
