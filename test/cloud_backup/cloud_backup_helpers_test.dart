import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/services/cloud_backup/cloud_backup_helpers.dart';

void main() {
  group('cloudBackupFileName', () {
    test('mirrors the local export name: prefix + ISO8601 with ":" -> "-" + .json', () {
      final name = cloudBackupFileName(
        prefix: 'obtainx-export',
        at: DateTime(2026, 7, 27, 9, 30, 5, 123, 456),
      );
      expect(
        name,
        'obtainx-export-2026-07-27T09-30-05.123456.json',
      );
    });

    test('produces a .json extension', () {
      final name = cloudBackupFileName(
        prefix: 'obtainx-export',
        at: DateTime(2026, 1, 2, 3, 4, 5),
      );
      expect(name.endsWith('.json'), isTrue);
    });
  });

  group('filterCloudCredsForImport', () {
    test('keeps a cloud cred from backup when the device has none', () {
      final backup = {
        'cloudBackupS3_secretAccessKey-creds': 'BK_SECRET',
        'theme': 'dark',
      };
      final device = <String, dynamic>{
        'cloudBackupS3_secretAccessKey-creds': '',
      };
      final out = filterCloudCredsForImport(backup, device);
      expect(out['cloudBackupS3_secretAccessKey-creds'], 'BK_SECRET');
      expect(out['theme'], 'dark');
    });

    test('drops a cloud cred from backup when the device already has one', () {
      final backup = {
        'cloudBackupS3_secretAccessKey-creds': 'BK_SECRET',
        'cloudBackupWebDav_password-creds': 'BK_PASS',
      };
      final device = <String, dynamic>{
        'cloudBackupS3_secretAccessKey-creds': 'DEVICE_SECRET',
      };
      final out = filterCloudCredsForImport(backup, device);
      expect(out.containsKey('cloudBackupS3_secretAccessKey-creds'), isFalse);
      expect(out['cloudBackupWebDav_password-creds'], 'BK_PASS');
    });

    test('leaves non-cloud creds alone (they follow normal import overwrite)', () {
      final backup = {
        'virusTotalApiKey': 'BK_VT',
        'someSource-creds': 'BK_SRC',
        'cloudBackupS3_secretAccessKey-creds': 'BK_S3',
      };
      final device = <String, dynamic>{
        'virusTotalApiKey': 'DEVICE_VT',
        'someSource-creds': 'DEVICE_SRC',
        'cloudBackupS3_secretAccessKey-creds': 'DEVICE_S3',
      };
      final out = filterCloudCredsForImport(backup, device);
      expect(out['virusTotalApiKey'], 'BK_VT');
      expect(out['someSource-creds'], 'BK_SRC');
      expect(out.containsKey('cloudBackupS3_secretAccessKey-creds'), isFalse);
    });

    test('handles a backup with no cloud creds', () {
      final backup = {'theme': 'dark'};
      final out = filterCloudCredsForImport(backup, {});
      expect(out, {'theme': 'dark'});
    });
  });

  test('cloudBackupCredsKeys all end with -creds', () {
    for (final k in cloudBackupCredsKeys) {
      expect(k.endsWith('-creds'), isTrue, reason: '$k must end with -creds');
    }
  });

  group('applyCredsImportRule', () {
    test('strips a device-owned cloud cred so import keeps the device value', () {
      const backup =
          '{"schemaVersion":2,"apps":[],"settings":{'
          '"theme":"dark",'
          '"cloudBackupS3_secretAccessKey-creds":"BK_S3"'
          '}}';
      final out = applyCredsImportRule(backup, {
        'cloudBackupS3_secretAccessKey-creds': 'DEVICE_S3',
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      final settings = decoded['settings'] as Map<String, dynamic>;
      expect(settings.containsKey('cloudBackupS3_secretAccessKey-creds'), isFalse);
      expect(settings['theme'], 'dark');
    });

    test('keeps a backup cloud cred when the device has none', () {
      const backup =
          '{"schemaVersion":2,"apps":[],"settings":{'
          '"cloudBackupWebDav_password-creds":"BK_PASS"'
          '}}';
      final out = applyCredsImportRule(backup, const {});
      final settings = (jsonDecode(out) as Map)['settings'] as Map<String, dynamic>;
      expect(settings['cloudBackupWebDav_password-creds'], 'BK_PASS');
    });

    test('leaves a backup with no settings block intact', () {
      const backup = '{"schemaVersion":2,"apps":[],"settings":{}}';
      final out = applyCredsImportRule(backup, const {});
      expect(jsonDecode(out), jsonDecode(backup));
    });
  });
}
