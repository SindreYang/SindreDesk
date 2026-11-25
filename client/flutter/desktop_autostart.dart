import 'dart:io';

/// 查询系统级服务，不在便携目录中注册高权限服务。
class DesktopAutostart {
  static bool get supported => Platform.isWindows || Platform.isLinux;

  static Future<bool> enabled() async {
    if (Platform.isWindows) {
      final result = await Process.run('powershell.exe', [
        '-NoProfile', '-NonInteractive', '-Command',
        r'''$ErrorActionPreference = 'Stop'; $s = Get-CimInstance Win32_Service -Filter "Name='SindreDeskHost'"; if ($s -and $s.StartMode -eq 'Auto') { Write-Output 'enabled' }''',
      ]);
      if (result.exitCode != 0) throw StateError('Service query failed');
      return result.stdout.toString().trim() == 'enabled';
    }
    if (Platform.isLinux) {
      final result = await Process.run('systemctl', ['is-enabled', 'sindredesk-host.service']);
      return result.exitCode == 0 && result.stdout.toString().trim() == 'enabled';
    }
    throw UnsupportedError('Desktop only');
  }

  static Future<void> requestChange(bool value) async {
    if (!supported) throw UnsupportedError('Desktop only');
    await Process.start(Platform.resolvedExecutable,
      [value ? '--install-service' : '--uninstall-service'],
      mode: ProcessStartMode.detached);
  }
}
