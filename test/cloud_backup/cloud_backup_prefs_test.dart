import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/services/cloud_backup/cloud_backup_prefs.dart';

void main() {
  group('cloudBackupConfigFromPrefs', () {
    test('maps every pref to the matching config field', () {
      final cfg = cloudBackupConfigFromPrefs(
        (k) => const {
          'cloudBackupActive': 's3',
          'cloudBackupS3_endpoint': 'https://s3.example.com',
          'cloudBackupS3_bucket': 'bkt',
          'cloudBackupS3_region': 'eu-west-1',
          'cloudBackupS3_prefix': 'obk/',
          'cloudBackupS3_accessKeyId': 'AKID',
          'cloudBackupS3_secretAccessKey-creds': 'SECRET',
          'cloudBackupWebDav_baseUrl': 'https://dav.example.com/dav/',
          'cloudBackupWebDav_prefix': 'obk/',
          'cloudBackupWebDav_username': 'u',
          'cloudBackupWebDav_password-creds': 'P',
        }[k],
      );

      expect(cfg.active, CloudBackend.s3);
      expect(cfg.s3Endpoint, 'https://s3.example.com');
      expect(cfg.s3Bucket, 'bkt');
      expect(cfg.s3Region, 'eu-west-1');
      expect(cfg.s3Prefix, 'obk/');
      expect(cfg.s3AccessKey, 'AKID');
      expect(cfg.s3SecretKey, 'SECRET');
      expect(cfg.webdavBaseUrl, 'https://dav.example.com/dav/');
      expect(cfg.webdavPrefix, 'obk/');
      expect(cfg.webdavUsername, 'u');
      expect(cfg.webdavPassword, 'P');
    });

    test('empty prefs yield a none-active, all-empty config', () {
      final cfg = cloudBackupConfigFromPrefs((_) => null);
      expect(cfg.active, CloudBackend.none);
      expect(cfg.s3Endpoint, '');
      expect(cfg.webdavBaseUrl, '');
    });

    test('parses webdav as the active backend', () {
      final cfg = cloudBackupConfigFromPrefs(
        (k) => k == 'cloudBackupActive' ? 'webdav' : null,
      );
      expect(cfg.active, CloudBackend.webdav);
    });
  });

  group('saveCloudBackupConfig', () {
    test('writes every config field back under its pref key', () {
      final written = <String, String>{};
      saveCloudBackupConfig(
        (k, v) => written[k] = v,
        const CloudBackupConfig(
          active: CloudBackend.s3,
          s3Endpoint: 'https://s3.example.com',
          s3Bucket: 'bkt',
          s3Region: 'eu-west-1',
          s3Prefix: 'obk/',
          s3AccessKey: 'AKID',
          s3SecretKey: 'SECRET',
          webdavBaseUrl: 'https://dav.example.com/dav/',
          webdavPrefix: 'obk/',
          webdavUsername: 'u',
          webdavPassword: 'P',
        ),
      );
      expect(written['cloudBackupActive'], 's3');
      expect(written['cloudBackupS3_endpoint'], 'https://s3.example.com');
      expect(written['cloudBackupS3_bucket'], 'bkt');
      expect(written['cloudBackupS3_region'], 'eu-west-1');
      expect(written['cloudBackupS3_prefix'], 'obk/');
      expect(written['cloudBackupS3_accessKeyId'], 'AKID');
      expect(written['cloudBackupS3_secretAccessKey-creds'], 'SECRET');
      expect(
        written['cloudBackupWebDav_baseUrl'],
        'https://dav.example.com/dav/',
      );
      expect(written['cloudBackupWebDav_prefix'], 'obk/');
      expect(written['cloudBackupWebDav_username'], 'u');
      expect(written['cloudBackupWebDav_password-creds'], 'P');
    });

    test('round-trips through load -> save -> load unchanged', () {
      final original = <String, String>{
        'cloudBackupActive': 'webdav',
        'cloudBackupWebDav_baseUrl': 'https://h/dav/',
        'cloudBackupWebDav_password-creds': 'secret',
      };
      final cfg = cloudBackupConfigFromPrefs((k) => original[k]);
      final saved = <String, String>{};
      saveCloudBackupConfig((k, v) => saved[k] = v, cfg);
      expect(saved['cloudBackupActive'], 'webdav');
      expect(saved['cloudBackupWebDav_baseUrl'], 'https://h/dav/');
      expect(saved['cloudBackupWebDav_password-creds'], 'secret');
    });
  });

  test('cloud secret pref keys match the creds-keys contract', () {
    // The loader reads secrets under the exact keys isSecretSettingKey knows.
    expect(cloudBackupPrefKeyS3Secret, 'cloudBackupS3_secretAccessKey-creds');
    expect(
      cloudBackupPrefKeyWebDavPassword,
      'cloudBackupWebDav_password-creds',
    );
  });
}
