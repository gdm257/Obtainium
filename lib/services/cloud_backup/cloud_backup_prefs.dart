import 'package:obtainium/services/cloud_backup/cloud_backup_service.dart';
export 'package:obtainium/services/cloud_backup/cloud_backup_service.dart';

/// SharedPreferences keys for the cloud-backup feature. The two secret keys end
/// in `-creds` so the existing [isSecretSettingKey] recognizes them and
/// `generateExportJSON` carries them in the "all settings" export with zero
/// changes — the whole "creds travel in the export JSON" requirement is met by
/// this naming convention alone.
const String cloudBackupPrefKeyActive = 'cloudBackupActive';
const String cloudBackupPrefKeyS3Endpoint = 'cloudBackupS3_endpoint';
const String cloudBackupPrefKeyS3Bucket = 'cloudBackupS3_bucket';
const String cloudBackupPrefKeyS3Region = 'cloudBackupS3_region';
const String cloudBackupPrefKeyS3Prefix = 'cloudBackupS3_prefix';
const String cloudBackupPrefKeyS3AccessKey = 'cloudBackupS3_accessKeyId';
const String cloudBackupPrefKeyS3Secret = 'cloudBackupS3_secretAccessKey-creds';
const String cloudBackupPrefKeyWebDavBaseUrl = 'cloudBackupWebDav_baseUrl';
const String cloudBackupPrefKeyWebDavPrefix = 'cloudBackupWebDav_prefix';
const String cloudBackupPrefKeyWebDavUsername = 'cloudBackupWebDav_username';
const String cloudBackupPrefKeyWebDavPassword = 'cloudBackupWebDav_password-creds';

/// Reads cloud-backup prefs into a [CloudBackupConfig]. [read] is the
/// nullable-string getter (e.g. `settingsProvider.getSettingString`); a null
/// or empty value maps to an empty field. Pure: no SharedPreferences import, so
/// it is unit-testable with a map-backed getter.
CloudBackupConfig cloudBackupConfigFromPrefs(String? Function(String) read) {
  String s(String k) => read(k) ?? '';
  return CloudBackupConfig(
    active: _parseBackend(s(cloudBackupPrefKeyActive)),
    s3Endpoint: s(cloudBackupPrefKeyS3Endpoint),
    s3Bucket: s(cloudBackupPrefKeyS3Bucket),
    s3Region: s(cloudBackupPrefKeyS3Region),
    s3Prefix: s(cloudBackupPrefKeyS3Prefix),
    s3AccessKey: s(cloudBackupPrefKeyS3AccessKey),
    s3SecretKey: s(cloudBackupPrefKeyS3Secret),
    webdavBaseUrl: s(cloudBackupPrefKeyWebDavBaseUrl),
    webdavPrefix: s(cloudBackupPrefKeyWebDavPrefix),
    webdavUsername: s(cloudBackupPrefKeyWebDavUsername),
    webdavPassword: s(cloudBackupPrefKeyWebDavPassword),
  );
}

/// Writes a [CloudBackupConfig] back via [write] (e.g.
/// `settingsProvider.setSettingString`). Mirror of [cloudBackupConfigFromPrefs].
void saveCloudBackupConfig(
  void Function(String key, String value) write,
  CloudBackupConfig cfg,
) {
  write(cloudBackupPrefKeyActive, _formatBackend(cfg.active));
  write(cloudBackupPrefKeyS3Endpoint, cfg.s3Endpoint);
  write(cloudBackupPrefKeyS3Bucket, cfg.s3Bucket);
  write(cloudBackupPrefKeyS3Region, cfg.s3Region);
  write(cloudBackupPrefKeyS3Prefix, cfg.s3Prefix);
  write(cloudBackupPrefKeyS3AccessKey, cfg.s3AccessKey);
  write(cloudBackupPrefKeyS3Secret, cfg.s3SecretKey);
  write(cloudBackupPrefKeyWebDavBaseUrl, cfg.webdavBaseUrl);
  write(cloudBackupPrefKeyWebDavPrefix, cfg.webdavPrefix);
  write(cloudBackupPrefKeyWebDavUsername, cfg.webdavUsername);
  write(cloudBackupPrefKeyWebDavPassword, cfg.webdavPassword);
}

CloudBackend _parseBackend(String raw) {
  switch (raw) {
    case 's3':
      return CloudBackend.s3;
    case 'webdav':
      return CloudBackend.webdav;
    default:
      return CloudBackend.none;
  }
}

String _formatBackend(CloudBackend b) {
  switch (b) {
    case CloudBackend.s3:
      return 's3';
    case CloudBackend.webdav:
      return 'webdav';
    case CloudBackend.none:
      return '';
  }
}