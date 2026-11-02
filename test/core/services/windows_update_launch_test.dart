import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  for (final folder in ['ascii', "中文 path's; \$name"]) {
    test('helper survives parent and releases its folder: $folder', () async {
      final root = await Directory.systemTemp.createTemp(
        'update-launch-fixture-',
      );
      try {
        final scripts = await Directory(p.join(root.path, folder)).create();
        final app = await Directory(p.join(root.path, 'app')).create();
        await File(
          p.join(app.path, 'keep.txt'),
        ).writeAsString('fixture payload');
        final marker = File(p.join(root.path, 'completed.txt'));
        final dart = File.fromUri(
          File(
            Platform.resolvedExecutable,
          ).parent.uri.resolve('../../../dart-sdk/bin/dart.exe'),
        );
        expect(await dart.exists(), isTrue);
        expect(app.parent.absolute.path, root.absolute.path);
        expect(p.dirname('${app.path}.old'), root.absolute.path);
        final parent = await Process.run(dart.path, [
          File('test/fixtures/windows_update_launch_parent.dart').absolute.path,
          p.join(scripts.path, 'update.ps1'),
          marker.path,
          app.path,
        ], workingDirectory: app.path).timeout(const Duration(seconds: 20));
        expect(parent.exitCode, 0, reason: '${parent.stdout}${parent.stderr}');
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!await marker.exists() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(await marker.exists(), isTrue);
        expect(await marker.readAsString(), '父进程退出后完成');
        expect(await app.exists(), isFalse);
        expect(
          await File(p.join('${app.path}.old', 'keep.txt')).readAsString(),
          'fixture payload',
        );
        final childPid = int.parse(
          await File('${marker.path}.pid').readAsString(),
        );
        final wait = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Get-Process -Id $childPid -ErrorAction SilentlyContinue | '
              'Wait-Process -Timeout 10 -ErrorAction Stop; exit 0',
        ]);
        expect(wait.exitCode, 0, reason: '${wait.stdout}${wait.stderr}');
      } finally {
        expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
        expect(p.basename(root.path), startsWith('update-launch-fixture-'));
        await root.delete(recursive: true);
      }
    }, skip: !Platform.isWindows);
  }
}
