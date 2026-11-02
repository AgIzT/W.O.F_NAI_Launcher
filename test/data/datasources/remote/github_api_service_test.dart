import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/data/datasources/remote/github_api_service.dart';

void main() {
  for (final platform in ['windows-installer', 'windows-portable']) {
    for (final manifest in [
      'json',
      'octet-stream',
      'missing',
      'invalid',
      'list',
    ]) {
      test(
        'release remains installable: $platform manifest=$manifest',
        () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final base = 'http://${server.address.address}:${server.port}';
          final githubHash = 'a' * 64;
          final manifestHash = 'b' * 64;
          const files = [
            'Studio_Windows_Setup.exe',
            'Studio_Windows_Portable.zip',
          ];
          server.listen((request) async {
            if (request.uri.path.endsWith('/releases/latest')) {
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                jsonEncode({
                  'tag_name': 'v9.0.0',
                  'html_url': '$base/release',
                  'assets': [
                    for (final file in files)
                      {
                        'name': file,
                        'browser_download_url': '$base/$file',
                        'size': 123,
                        'digest': 'sha256:$githubHash',
                      },
                    if (manifest != 'missing')
                      {
                        'name': 'release_manifest.json',
                        'browser_download_url': '$base/manifest',
                      },
                  ],
                }),
              );
            } else if (request.uri.path == '/manifest') {
              request.response.headers.contentType = manifest == 'json'
                  ? ContentType.json
                  : ContentType.binary;
              request.response.write(switch (manifest) {
                'invalid' => '{broken',
                'list' => '[]',
                _ => jsonEncode({
                  'assets': [
                    for (final file in files)
                      {'fileName': file, 'sha256': manifestHash},
                  ],
                }),
              });
            } else {
              request.response.statusCode = HttpStatus.notFound;
            }
            await request.response.close();
          });
          final dio = Dio(BaseOptions(baseUrl: base));
          try {
            final info = await GitHubApiService(dio: dio).fetchLatestRelease(
              owner: 'fixture',
              repo: 'launcher',
              currentVersion: '1.0.0',
              platform: platform,
            );
            expect(info.supportsInAppInstall, isTrue);
            expect(info.primaryAsset!.typeId, platform);
            expect(
              info.primaryAsset!.sha256,
              ['json', 'octet-stream'].contains(manifest)
                  ? manifestHash
                  : githubHash,
            );
            expect(info.primaryAsset!.size, 123);
            expect(info.htmlUrl, '$base/release');
          } finally {
            dio.close(force: true);
            await server.close(force: true);
          }
        },
      );
    }
  }
}
