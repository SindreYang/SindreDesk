import 'dart:convert';
import 'dart:io';

/// 当前用户登录后启动 Host，不安装系统服务。
class DesktopAutostart {
  static bool get supported => Platform.isWindows || Platform.isLinux;

  static File _entry() {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData == null || appData.isEmpty) {
        throw StateError('APPDATA unavailable');
      }
      return File('$appData\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\SindreDesk Host.lnk');
    }
    if (Platform.isLinux) {
      final config = Platform.environment['XDG_CONFIG_HOME'];
      final home = Platform.environment['HOME'];
      final root = config != null && config.startsWith('/')
          ? config
          : home != null && home.startsWith('/') ? '$home/.config' : null;
      if (root == null) throw StateError('Configuration directory unavailable');
      return File('$root/autostart/sindredesk-host.desktop');
    }
    throw UnsupportedError('Desktop only');
  }

  static Future<bool> enabled() => _entry().exists();

  static String desktopExec(String path) {
    if (path.contains('\n') || path.contains('\r') || path.contains('\u0000')) {
      throw ArgumentError('Unsupported executable path');
    }
    final arg = path.replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"').replaceAll('\x60', '\\\x60')
        .replaceAll('\$', '\\\$').replaceAll('%', '%%');
    return '"$arg"'.replaceAll('\\', '\\\\');
  }

  static String _psString(String s) => "'" + s.replaceAll("'", "''") + "'";

  static Future<void> setEnabled(bool value) async {
    final entry = _entry();
    if (!value) {
      if (await entry.exists()) await entry.delete();
      return;
    }
    final executable = Platform.resolvedExecutable;
    final workingDirectory = File(executable).parent.path;
    await entry.parent.create(recursive: true);
    if (Platform.isWindows) {
      final script = [
        r'$shell = New-Object -ComObject WScript.Shell',
        r'$link = $shell.CreateShortcut(' + _psString(entry.path) + ')',
        r'$link.TargetPath = ' + _psString(executable),
        r'$link.WorkingDirectory = ' + _psString(workingDirectory),
        r"$link.Description = 'SindreDesk Host'",
        r'$link.Save()',
      ].join('\n');
      final bytes = <int>[];
      for (final unit in script.codeUnits) {
        bytes.add(unit & 255);
        bytes.add(unit >> 8);
      }
      final result = await Process.run('powershell.exe', [
        '-NoProfile', '-NonInteractive', '-EncodedCommand', base64Encode(bytes)
      ]);
      if (result.exitCode != 0 || !await entry.exists()) {
        throw StateError('Unable to create startup shortcut');
      }
    } else {
      final contents = '[Desktop Entry]\nType=Application\nName=SindreDesk Host\n'
          'Exec=' + desktopExec(executable) + '\nTerminal=false\n'
          'X-GNOME-Autostart-enabled=true\n';
      final temporary = await entry.parent.createTemp('.sindredesk-');
      try {
        final file = File(temporary.path + '/entry.desktop');
        await file.writeAsString(contents, flush: true);
        await file.rename(entry.path);
      } finally {
        await temporary.delete(recursive: true);
      }
    }
  }
}
