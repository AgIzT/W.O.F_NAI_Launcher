import 'dart:convert';
import 'dart:io';

import 'package:nai_launcher/core/services/windows_update_script.dart';

/// Disposable parent; the child must outlive it and release its working folder.
Future<void> main(List<String> arguments) async {
  final script = File(arguments[0]);
  final marker = arguments[1].replaceAll("'", "''");
  final app = arguments[2].replaceAll("'", "''");
  await script.writeAsBytes([
    0xef,
    0xbb,
    0xbf,
    ...utf8.encode('''
\$ErrorActionPreference = 'Stop'
while (Get-Process -Id $pid -ErrorAction SilentlyContinue) {
  Start-Sleep -Milliseconds 50
}
Move-Item -LiteralPath '$app' -Destination '$app.old'
[IO.File]::WriteAllText('$marker.pid', [string]\$PID)
[IO.File]::WriteAllText('$marker', '父进程退出后完成')
'''),
  ]);
  await WindowsUpdateScript.launch(script.path);
  exit(0);
}
