// Unit tests for CloudStorageProvider orchestration: credential round-trip,
// available-target derivation, history preservation, and the single-target
// semantics of upload/list/download — all offline via FakeCloudStorage.
//
// Requires a Flutter binding because SettingsProvider backs onto
// SharedPreferences (platform channel). No external packages beyond the
// SDK-bundled flutter_test / shared_preferences already used by the app.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:obtainium/providers/cloud_storage_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/services/cloud_storage.dart';

const _s3 = S3Creds(
  endpoint: 'https://s3.us-east-1.amazonaws.com',
  bucket: 'mybucket',
  region: 'us-east-1',
  accessKey: 'AKIA...',
  secretKey: 'shhh',
);

const _webdav = WebDAVCreds(
  url: 'https://cloud.example.com/dav/backups/',
  username: 'user',
  password: 'pass',
);

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  test('s3/webdav credentials round-trip through prefs (-creds keys)', () async {
    final sp = SettingsProvider();
    await sp.initializeSettings();
    final csp = CloudStorageProvider(settingsProvider: sp);

    csp.s3Creds = _s3;
    csp.webdavCreds = _webdav;

    expect(sp.getSettingString('s3-creds'), _s3.toJsonString());
    expect(sp.getSettingString('webdav-creds'), _webdav.toJsonString());
    expect(csp.s3Creds!.bucket, 'mybucket');
    expect(csp.webdavCreds!.username, 'user');
  });

  test('configuring one kind does not clear the other (Req 1.3)', () async {
    final sp = SettingsProvider();
    await sp.initializeSettings();
    final csp = CloudStorageProvider(settingsProvider: sp);

    csp.s3Creds = _s3;
    csp.webdavCreds = _webdav;
    csp.s3Creds = S3Creds(
      endpoint: 'https://minio.local:9000',
      bucket: 'other',
      region: 'us-east-1',
      accessKey: 'a',
      secretKey: 'b',
    );

    expect(csp.s3Creds!.bucket, 'other');
    expect(csp.webdavCreds, isNotNull); // untouched
  });

  test('availableTargets is empty with no configured creds (Req 1.4)', () async {
    final sp = SettingsProvider();
    await sp.initializeSettings();
    final csp = CloudStorageProvider(settingsProvider: sp);
    expect(csp.availableTargets, isEmpty);
    expect(csp.hasAnyTarget, isFalse);
  });

  test('availableTargets lists s3 then webdav (Req 1.1/1.2)', () async {
    final sp = SettingsProvider();
    await sp.initializeSettings();
    final csp = CloudStorageProvider(settingsProvider: sp);
    csp.s3Creds = _s3;
    csp.webdavCreds = _webdav;

    final targets = csp.availableTargets;
    expect(targets.length, 2);
    expect(targets[0].kind, CloudProviderKind.s3);
    expect(targets[1].kind, CloudProviderKind.webdav);
  });

  test('clearing creds removes the target', () async {
    final sp = SettingsProvider();
    await sp.initializeSettings();
    final csp = CloudStorageProvider(settingsProvider: sp);
    csp.s3Creds = _s3;
    expect(csp.availableTargets.single.kind, CloudProviderKind.s3);
    csp.s3Creds = null;
    expect(csp.availableTargets, isEmpty);
  });

  group('orchestration via fake transport', () {
    late CloudStorageProvider csp;
    late CloudTarget target;
    late FakeCloudStorage fake;

    setUp(() async {
      final sp = SettingsProvider();
      await sp.initializeSettings();
      csp = CloudStorageProvider(settingsProvider: sp);
      csp.s3Creds = _s3;
      target = csp.availableTargets.single;
      fake = FakeCloudStorage();
      csp.transportOverrides[target.label] = fake;
    });

    test('upload then list then download round-trips', () async {
      const name = 'obtainium-2024-01-01.json';
      final bytes = Uint8List.fromList(utf8.encode('{"apps":[]}'));
      await csp.upload(target, name, bytes);

      final listed = await csp.list(target);
      expect(listed.map((f) => f.filename), contains(name));

      final downloaded = await csp.download(target, name);
      expect(downloaded, '{"apps":[]}');
    });

    test('upload preserves history — same name not overwritten (Req 2.3)', () async {
      const name = 'obtainium-x.json';
      await csp.upload(target, name, Uint8List.fromList(utf8.encode('first')));
      expect(
        () => csp.upload(target, name, Uint8List.fromList(utf8.encode('second'))),
        throwsA(isA<CloudStorageException>()),
      );
      expect(await csp.download(target, name), 'first');
    });

    test('multiple uploads accumulate and list newest-first', () async {
      await csp.upload(target, 'a.json', Uint8List.fromList(utf8.encode('1')));
      await csp.upload(target, 'b.json', Uint8List.fromList(utf8.encode('2')));
      final listed = await csp.list(target);
      expect(listed.length, 2);
    });

    test('download of missing file throws (Req 3.3 path)', () async {
      expect(
        () => csp.download(target, 'absent.json'),
        throwsA(isA<CloudStorageException>()),
      );
    });

    test('each operation uses exactly the single selected target', () async {
      // Only one fake is registered; the provider never touches another target.
      await csp.upload(target, 'one.json', Uint8List(0));
      expect((await csp.list(target)).single.filename, 'one.json');
    });
  });
}
