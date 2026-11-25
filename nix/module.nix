# NixOS module for the immurok BLE fingerprint key.
#
# Mirrors what upstream's distribution packages install (packaging/stage.sh,
# packaging/scripts/postinstall.sh), but declaratively: the PAM lines that
# upstream's `immurok-pam-helper` writes into /etc/pam.d are generated here.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  configuration = config.services.immurok;

  # Hard-coded upstream: the daemon unit's User=/Group=, the polkit rule, the
  # D-Bus policy and the PAM module's socket ownership check (pam/pam_immurok.c).
  daemonUser = "immurok";

  # Upstream's helper adds `timeout=10` for polkit-1 (scripts/immurok-pam-helper).
  polkitTimeoutSeconds = 10;

  # Place the module just before pam_unix so a touch short-circuits the password prompt.
  orderOffsetBeforeUnix = 10;

  autostartDesktopFile = "com.immurok.Settings.desktop";

  pamModulePath = "${configuration.package}/lib/security/pam_immurok.so";

  pamRuleFor = serviceName: {
    name = serviceName;
    value.rules.auth.immurok = {
      order = config.security.pam.services.${serviceName}.rules.auth.unix.order - orderOffsetBeforeUnix;
      control = "sufficient";
      modulePath = pamModulePath;
      settings = lib.optionalAttrs (configuration.pam.timeoutByService ? ${serviceName}) {
        timeout = configuration.pam.timeoutByService.${serviceName};
      };
    };
  };
in
{
  options.services.immurok = {
    enable = lib.mkEnableOption "the immurok BLE fingerprint key daemon and session agent";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The immurok package to use.";
    };

    pam.services = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "sudo"
        "polkit-1"
      ];
      description = ''
        PAM services in which `pam_immurok.so` is added as a `sufficient` auth
        rule before `pam_unix`. Upstream supports `sudo` and `polkit-1`; screen
        unlock is handled by the daemon through logind, not through PAM.
      '';
    };

    pam.timeoutByService = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.positive;
      default = {
        "polkit-1" = polkitTimeoutSeconds;
      };
      description = "Per-service `timeout=` argument (seconds) passed to `pam_immurok.so`.";
    };

    autostartGui = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to autostart the resident immurok settings/quick-fill app in graphical sessions.";
    };

    daemonArguments = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--debug" ];
      description = "Extra arguments for immurok-daemon. `--debug` logs raw BLE frames, including key material.";
    };
  };

  config = lib.mkIf configuration.enable {
    assertions = [
      {
        assertion = config.hardware.bluetooth.enable;
        message = "services.immurok requires hardware.bluetooth.enable = true (the daemon talks to BlueZ over D-Bus).";
      }
    ];

    environment.systemPackages = [ configuration.package ];

    environment.etc."xdg/autostart/${autostartDesktopFile}" = lib.mkIf configuration.autostartGui {
      source = "${configuration.package}/share/immurok/autostart/${autostartDesktopFile}";
    };

    users.users.${daemonUser} = {
      isSystemUser = true;
      group = daemonUser;
      description = "immurok fingerprint daemon";
    };
    users.groups.${daemonUser} = { };

    # Grants the daemon user access to org.bluez (packaging/dbus/immurok.conf),
    # and D-Bus activation of the GUI (com.immurok.Settings.service).
    services.dbus.packages = [ configuration.package ];

    systemd.packages = [ configuration.package ];
    systemd.tmpfiles.packages = [ configuration.package ];

    systemd.services.immurok-daemon = {
      wantedBy = [ "multi-user.target" ];
      environment.IMMUROK_DAEMON_ARGS = lib.escapeShellArgs configuration.daemonArguments;
    };

    systemd.user.services.immurok-session-agent.wantedBy = [ "default.target" ];

    # Lets the daemon lock/unlock the active session through logind (packaging/polkit/49-immurok.rules).
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (subject.user == "${daemonUser}" &&
            action.id == "org.freedesktop.login1.lock-sessions") {
          return polkit.Result.YES;
        }
      });
    '';

    security.pam.services = lib.listToAttrs (map pamRuleFor configuration.pam.services);
  };
}
