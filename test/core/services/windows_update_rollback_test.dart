import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/services/windows_update_script.dart';
import 'package:path/path.dart' as p;

void main() {
  for (final scenario in [
    'forward',
    'backward',
    'mixed',
    'existing-backup',
    'publish-failure',
    'rollback-failure',
  ]) {
    test(
      'portable update preserves correct payload and backup: $scenario',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'portable-update-fixture-',
        );
        final app = p.join(root.path, 'app');
        final backup = p.join(root.path, 'backup');
        final extract = p.join(root.path, 'extract');
        Future<void> write(String path, String value) async {
          final file = File(path);
          await file.parent.create(recursive: true);
          await file.writeAsString(value);
        }

        try {
          await write(p.join(app, 'nai_launcher.exe'), 'old program');
          await write(p.join(app, 'data/app.so'), 'old aot');
          await write(p.join(app, 'tools/agent/retired.mjs'), 'retired code');
          await write(p.join(app, 'custom/keep.txt'), 'custom file');
          await write(p.join(app, 'user-data/draft.txt'), 'original draft');
          final separator = scenario == 'backward' ? '\\' : '/';
          await write(
            p.join(app, 'app_files_manifest.json'),
            jsonEncode({
              'files': [
                'nai_launcher.exe',
                ['data', 'app.so'].join(separator),
                scenario == 'mixed'
                    ? r'tools/agent\retired.mjs'
                    : ['tools', 'agent', 'retired.mjs'].join(separator),
              ],
            }),
          );
          if (scenario == 'existing-backup') {
            await write(
              p.join(backup, 'prior.txt'),
              'previous recovery backup',
            );
          }
          final archive = Archive();
          for (final entry in {
            'nai_launcher.exe': 'new program',
            'data/app.so': 'new aot',
            'app_files_manifest.json': '{"files":[]}',
          }.entries) {
            final bytes = utf8.encode(entry.value);
            archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
          }
          final zip = p.join(root.path, 'update.zip');
          await File(zip).writeAsBytes(ZipEncoder().encode(archive)!);
          final resultFile = File(p.join(root.path, 'result.json'));
          final generated = WindowsUpdateScript.buildPortableScript(
            appPid: 2147483647,
            version: 'fixture',
            zipPath: zip,
            appDirectory: app,
            executableName: 'nai_launcher.exe',
            extractDirectory: extract,
            backupDirectory: backup,
            resultPath: resultFile.path,
            pendingMetadataPath: p.join(root.path, 'pending.json'),
            logPath: p.join(root.path, 'update.log'),
          );
          const overrides = r'''
function Start-Sleep {}
function Start-Process {
  param([string]$FilePath, [switch]$PassThru)
  if ($env:FIXTURE_SCENARIO -eq 'rollback-failure') {
    return [PSCustomObject]@{ HasExited = $true; ExitCode = 7 }
  }
  return [PSCustomObject]@{ HasExited = $false; ExitCode = 0 }
}
''';
          final script = File(p.join(root.path, 'update.ps1'));
          var scenarioScript = generated;
          if (scenario == 'publish-failure') {
            scenarioScript = scenarioScript.replaceFirst(
              r'Move-Item -LiteralPath $SourceDir -Destination $AppDir',
              "throw 'synthetic publish failure'",
            );
          } else if (scenario == 'rollback-failure') {
            scenarioScript = scenarioScript.replaceFirst(
              r'Move-Item -LiteralPath $BackupDir -Destination $AppDir',
              "throw 'synthetic restore failure'",
            );
          }
          await script.writeAsBytes([
            0xef,
            0xbb,
            0xbf,
            ...utf8.encode(overrides + scenarioScript),
          ]);
          // Every recursively moved/deleted directory is a direct fixture child.
          for (final path in [app, backup, extract]) {
            expect(
              p.dirname(p.normalize(p.absolute(path))),
              root.absolute.path,
            );
          }
          final result = await Process.run(
            'powershell.exe',
            [
              '-NoProfile',
              '-NonInteractive',
              '-ExecutionPolicy',
              'Bypass',
              '-File',
              script.path,
            ],
            environment: {
              'FIXTURE_SCENARIO': scenario,
              'FIXTURE_EXTRACT': extract,
              'FIXTURE_BACKUP': backup,
            },
          );
          final success = ['forward', 'backward', 'mixed'].contains(scenario);
          expect(
            result.exitCode,
            success ? 0 : 1,
            reason:
                '${result.stdout}${result.stderr}\n'
                '${await File(p.join(root.path, 'update.log')).readAsString()}\n'
                '${await resultFile.readAsString()}',
          );
          final status = jsonDecode(await resultFile.readAsString()) as Map;
          expect(status['success'], success);
          if (success) {
            expect(
              await File(p.join(app, 'data/app.so')).readAsString(),
              'new aot',
            );
            expect(
              await File(p.join(app, 'tools/agent/retired.mjs')).exists(),
              isFalse,
            );
            expect(
              await File(p.join(app, 'custom/keep.txt')).readAsString(),
              'custom file',
            );
          } else if (scenario == 'existing-backup') {
            expect(
              await File(p.join(backup, 'prior.txt')).readAsString(),
              'previous recovery backup',
            );
            expect(
              await File(p.join(app, 'nai_launcher.exe')).readAsString(),
              'old program',
            );
          } else if (scenario == 'publish-failure') {
            expect(
              await File(p.join(app, 'nai_launcher.exe')).readAsString(),
              'old program',
            );
          } else {
            expect(status['message'], contains('Rollback failed'));
            expect(
              await File(p.join(backup, 'nai_launcher.exe')).readAsString(),
              'old program',
            );
            expect(
              await File(p.join(backup, 'user-data/draft.txt')).readAsString(),
              'original draft',
            );
          }
          if (scenario != 'rollback-failure') {
            expect(
              await File(p.join(app, 'user-data/draft.txt')).readAsString(),
              'original draft',
            );
          }
        } finally {
          expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
          expect(p.basename(root.path), startsWith('portable-update-fixture-'));
          await root.delete(recursive: true);
        }
      },
      skip: !Platform.isWindows,
    );
  }
}
