{
  # Create an attrsOf module wrapper (`services.${name}`) around the given submodule.
  #
  # where module filename is of form `${name}.nix`. The submodule takes this
  # 'name' parameter, and is expected to set the final process-compose config in
  # its `outputs.settings` option.
  multiService = mod:
    { config, pkgs, lib, ... }:
    let
      # Derive name from filename
      service = lib.pipe mod [
        builtins.baseNameOf
        (lib.strings.splitString ".")
        builtins.head
      ];
      serviceModule = { config, name, ... }: {
        options = {
          enable = lib.mkEnableOption "Enable the ${service}.<name> service";
          dataDir = lib.mkOption {
            type = lib.types.str;
            default = "./.data/${name}";
            description = "The directory where all data for `${service}.<name>` is stored";
          };
          logDir = lib.mkOption {
            type = lib.types.str;
            default = "./.logs/${name}";
            description = "The directory where all logs for `${service}.<name>` are stored";
          };
          namespace = lib.mkOption {
            description = "Namespace for the ${service} service";
            default = "${service}.${name}";
            type = lib.types.str;
          };
          outputs = {
            defaultProcessSettings = lib.mkOption {
              type = lib.types.deferredModule;
              internal = true;
              readOnly = true;
              description = "Default settings for all processes under the ${service} service";
              default = {
                namespace = lib.mkDefault config.namespace;
                is_daemon = lib.mkDefault false;
                is_foreground = lib.mkDefault false;
                is_tty = lib.mkDefault false;
                is_elevated = lib.mkDefault false;

                log_location = lib.mkDefault "${config.logDir}/${name}.log";
                logger_config = {
                  rotation = {
                    max_size_mb = lib.mkDefault 5;
                    max_backups = lib.mkDefault 3;
                    max_age_days = lib.mkDefault 7;
                    compress = lib.mkDefault false;
                  };
                  disable_json = lib.mkDefault true;
                  fields_order = lib.mkDefault [ "time" "level" "message" ];
                  no_color = lib.mkDefault true;
                  no_metadata = lib.mkDefault true;
                  add_timestamp = lib.mkDefault true;
                  timestamp_format = lib.mkDefault "2006-01-02T15:04:05Z07:00";
                  flush_each_line = lib.mkDefault false;
                };

                # https://github.com/F1bonacc1/process-compose#-auto-restart-if-not-healthy
                availability = {
                  restart = lib.mkDefault "on_failure";
                  backoff_seconds = lib.mkDefault 5;
                  max_restarts = lib.mkDefault 5;
                  exit_on_end = lib.mkDefault false;
                  exit_on_skipped = lib.mkDefault false;
                };
                readiness_probe = {
                  initial_delay_seconds = lib.mkDefault 2;
                  period_seconds = lib.mkDefault 10;
                  timeout_seconds = lib.mkDefault 4;
                  success_threshold = lib.mkDefault 1;
                  failure_threshold = lib.mkDefault 5;
                };
                liveness_probe = {
                  initial_delay_seconds = lib.mkDefault 2;
                  period_seconds = lib.mkDefault 10;
                  timeout_seconds = lib.mkDefault 4;
                  success_threshold = lib.mkDefault 1;
                  failure_threshold = lib.mkDefault 5;
                };
              };
            };
            settings = lib.mkOption {
              type = lib.types.lazyAttrsOf lib.types.raw;
              internal = true;
              description = "process-compose settings for the processes under the ${service} service";
              apply = v: v // {
                processes = lib.flip lib.mapAttrs v.processes (_: cfg:
                  { imports = [ config.outputs.defaultProcessSettings cfg ]; }
                );
              };
            };
          };
        };
      };
    in
    {
      options = {
        services.${service} = lib.mkOption {
          description = "${service} service";
          default = { };
          type = lib.types.attrsOf (lib.types.submoduleWith {
            specialArgs = { inherit pkgs; };
            modules = [
              serviceModule
              mod
            ];
          });
        };
      };
      config = {
        settings = {
          imports =
            lib.pipe config.services.${service} [
              (lib.filterAttrs (_: cfg: cfg.enable))
              (lib.mapAttrsToList (_: cfg: cfg.outputs.settings))
            ];
        };
      };
    };
}
