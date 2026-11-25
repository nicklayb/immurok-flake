# Immurok: BLE fingerprint key companion (daemon, session agent, CLI/TUI,
# GTK settings app, PAM module). Built from https://github.com/immurok/app-linux-rs
{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  glib,
  wrapGAppsHook4,
  makeWrapper,
  gobject-introspection,
  dbus,
  pam,
  gtk4,
  libadwaita,
  libnotify,
  systemd,
  python3,
}:

let
  version = "0.9.4";

  # Interpreter for ble-notify-helper.py, spawned by the daemon as `python3 <script>`.
  bluetoothHelperPython = python3.withPackages (pythonPackages: [ pythonPackages.dbus-fast ]);

  # Interpreter for the GTK4/libadwaita authorization dialog shown by the session agent.
  authDialogPython = python3.withPackages (pythonPackages: [ pythonPackages.pygobject3 ]);

  # Helper scripts shipped next to the binaries; the Rust code looks them up via current_exe().
  helperScripts = [
    "immurok-auth-dialog"
    "ble-notify-helper.py"
  ];
in
rustPlatform.buildRustPackage {
  pname = "immurok";
  inherit version;

  src = fetchFromGitHub {
    owner = "immurok";
    repo = "app-linux-rs";
    rev = "v${version}";
    hash = "sha256-DyPXYTilZvw3XYPZTerdHP2q3uWNXGm2MAXv5BkotNg=";
  };

  cargoHash = "sha256-iohheKYsPlw+LuZVz+900Adbr22RM4/Yqtn6K2d3oSA=";

  nativeBuildInputs = [
    pkg-config
    glib # glib-compile-resources for immurok-gui's build.rs
    wrapGAppsHook4
    makeWrapper
    gobject-introspection
  ];

  buildInputs = [
    dbus
    pam
    gtk4
    libadwaita
  ];

  # In the build sandbox PID 1 belongs to the build user, which this test assumes it never does.
  checkFlags = [ "--skip=tty::tests::pid_1_is_not_mine" ];

  # Wrapping is done selectively in postFixup: ble-notify-helper.py must stay a
  # plain Python file because the daemon passes it to `python3` as an argument.
  dontWrapGApps = true;

  # The PAM module is plain C outside the cargo workspace.
  postBuild = ''
    $CC -fPIC -Wall -Wextra -O2 -shared -o pam/pam_immurok.so pam/pam_immurok.c -lpam
  '';

  postInstall = ''
    install -Dm755 pam/pam_immurok.so $out/lib/security/pam_immurok.so

    ${lib.concatMapStringsSep "\n" (
      script: "install -Dm755 scripts/${script} $out/bin/${script}"
    ) helperScripts}
    substituteInPlace $out/bin/immurok-auth-dialog \
      --replace-fail '#!/usr/bin/python3' '#!${authDialogPython}/bin/python3'

    install -Dm644 packaging/immurok-daemon.service $out/lib/systemd/system/immurok-daemon.service
    install -Dm644 packaging/immurok-session-agent.service $out/lib/systemd/user/immurok-session-agent.service
    substituteInPlace $out/lib/systemd/system/immurok-daemon.service $out/lib/systemd/user/immurok-session-agent.service \
      --replace-fail /usr/bin/ $out/bin/

    install -Dm644 packaging/tmpfiles.d/immurok.conf $out/lib/tmpfiles.d/immurok.conf
    install -Dm644 packaging/sysusers.d/immurok.conf $out/lib/sysusers.d/immurok.conf
    install -Dm644 packaging/dbus/immurok.conf $out/share/dbus-1/system.d/immurok.conf
    install -Dm644 packaging/polkit/49-immurok.rules $out/share/polkit-1/rules.d/49-immurok.rules

    install -Dm644 packaging/com.immurok.Settings.service $out/share/dbus-1/services/com.immurok.Settings.service
    substituteInPlace $out/share/dbus-1/services/com.immurok.Settings.service \
      --replace-fail /usr/bin/ $out/bin/
    install -Dm644 packaging/com.immurok.Settings.desktop $out/share/applications/com.immurok.Settings.desktop
    install -Dm644 packaging/com.immurok.Settings.autostart.desktop $out/share/immurok/autostart/com.immurok.Settings.desktop
    for iconDirectory in packaging/icons/hicolor/*/apps; do
      size="$(basename "$(dirname "$iconDirectory")")"
      install -Dm644 "$iconDirectory/com.immurok.Settings.png" \
        "$out/share/icons/hicolor/$size/apps/com.immurok.Settings.png"
    done
  '';

  postFixup = ''
    wrapGApp $out/bin/immurok-gui
    wrapGApp $out/bin/immurok-auth-dialog

    wrapProgram $out/bin/immurok-daemon \
      --prefix PATH : ${
        lib.makeBinPath [
          bluetoothHelperPython
          systemd
        ]
      }

    wrapProgram $out/bin/immurok-session-agent \
      --prefix PATH : ${lib.makeBinPath [ libnotify ]}
  '';

  meta = {
    description = "Companion app for the immurok BLE fingerprint key (daemon, PAM module, CLI, GUI)";
    homepage = "https://github.com/immurok/app-linux-rs";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
    mainProgram = "immurok-cli";
  };
}
