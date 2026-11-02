import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/data/models/version/release_asset_info.dart';

void main() {
  group('ReleaseAssetInfo', () {
    test('retains and normalizes GitHub SHA-256 digests', () {
      final asset = ReleaseAssetInfo.fromGitHubAsset({
        'digest': 'sha256:${'ABCDEF01' * 8}',
      });
      expect(asset.sha256, 'abcdef01' * 8);
    });

    for (final digest in [
      null,
      7,
      '',
      'sha256:abc',
      'sha1:${'a' * 64}',
      'sha256:${'x' * 64}',
      'sha256:${'a' * 65}',
    ]) {
      test('ignores malformed or unsupported digest: $digest', () {
        expect(
          ReleaseAssetInfo.fromGitHubAsset({'digest': digest}).sha256,
          isNull,
        );
      });
    }

    test('detects Windows installer asset', () {
      final asset = ReleaseAssetInfo.fromGitHubAsset({
        'name': 'NAI_Launcher_Windows_1.0.0-beta13+16_Setup.exe',
        'browser_download_url': 'https://example.com/setup.exe',
        'size': 123,
      });

      expect(asset.type, ReleaseAssetType.windowsInstaller);
      expect(asset.platform, 'windows');
      expect(asset.supportsInAppInstall, isTrue);
      expect(asset.typeId, 'windows-installer');
    });

    test('detects portable assets', () {
      final windowsAsset = ReleaseAssetInfo.fromGitHubAsset({
        'name': 'NAI_Launcher_Windows_1.0.0_Portable.zip',
        'browser_download_url': 'https://example.com/windows.zip',
      });

      expect(windowsAsset.type, ReleaseAssetType.windowsPortable);
      expect(windowsAsset.supportsInAppInstall, isTrue);
      expect(windowsAsset.platform, 'windows');
    });

    test('merges manifest metadata with GitHub asset', () {
      final githubAsset = ReleaseAssetInfo.fromGitHubAsset({
        'name': 'NAI_Launcher_Windows_1.0.0_Setup.exe',
        'browser_download_url': 'https://example.com/setup.exe',
        'size': 123,
      });
      final asset = ReleaseAssetInfo.fromManifestAsset({
        'type': 'windows-installer',
        'fileName': 'NAI_Launcher_Windows_1.0.0_Setup.exe',
        'sha256': 'abc123',
        'description': '安装版',
      }, githubAsset: githubAsset);

      expect(asset.downloadUrl, githubAsset.downloadUrl);
      expect(asset.size, 123);
      expect(asset.sha256, 'abc123');
      expect(asset.description, '安装版');
    });
  });
}
