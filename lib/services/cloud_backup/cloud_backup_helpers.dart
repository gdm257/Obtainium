import 'dart:convert';
/// Pure helpers for the cloud-backup feature — no I/O, no Flutter/i18n deps.
///
/// Kept separate from the settings/http-backed facade so the logic that has to
/// be *correct* (filename shape, per-key creds conflict rule) is anchored by
/// unit tests rather than buried inside a class that touches SharedPreferences.
///
/// ponytail: the pref keys for cloud backend secrets end in `-creds`, so the
/// existing [isSecretSettingKey] in apps_provider_import_export.dart picks them
/// up and `generateExportJSON` needs zero changes — the whole "creds travel in
/// the export JSON" requirement is satisfied by the naming convention alone.

/// Secret pref keys owned by the cloud-backup feature. Each ends in `-creds` so
/// the existing export/import secret handling recognizes them automatically.
/// Add new cloud backend secret keys here — the import filter keys off this set.
const List<String> cloudBackupCredsKeys = [
  'cloudBackupS3_secretAccessKey-creds',
  'cloudBackupWebDav_password-creds',
];

/// Builds the cloud object name. Mirrors the local export file name
/// (`${prefix}-${ISO8601 with ":" -> "-"}.json`) so a cloud upload and a local
/// export produced at the same instant would carry the same timestamped stem —
/// the timestamp alone keeps versions unique (no overwrite).
String cloudBackupFileName({required String prefix, required DateTime at}) {
  final stamp = at.toIso8601String().replaceAll(':', '-');
  return '$prefix-$stamp.json';
}

/// Applies the cloud-backend creds import rule: for each cloud secret the
/// backup carries, keep the device's current value if it already has a
/// non-empty one, otherwise accept the backup value. Non-cloud keys pass
/// through unchanged (they follow the normal "last write wins" import path).
///
/// Returns a new map suitable to feed into the existing import routine; the
/// device-owned creds are simply *absent* from it so the importer never
/// overwrites them.
Map<String, dynamic> filterCloudCredsForImport(
  Map<String, dynamic> backupSettings,
  Map<String, dynamic> deviceSettings,
) {
  final out = Map<String, dynamic>.from(backupSettings);
  for (final key in cloudBackupCredsKeys) {
    if (!out.containsKey(key)) continue;
    final deviceVal = deviceSettings[key];
    final deviceHas =
        deviceVal != null && deviceVal.toString().isNotEmpty;
    if (deviceHas) {
      out.remove(key);
    }
  }
  return out;
}
/// Applies the cloud-creds import rule to a backup JSON string: for each cloud
/// secret in the backup's `settings` block, drop it when the device already has
/// a non-empty value (so the existing import path leaves the device value
/// untouched), otherwise leave the backup value to be written. Other settings
/// pass through unchanged.
///
/// Cloud backups always carry `schemaVersion` (produced by
/// `generateExportJSON`), so filtering the top-level `settings` map is enough;
/// no [ExportSchema] round-trip needed. Returns a JSON string ready for the
/// existing [AppsProvider.import].
String applyCredsImportRule(
  String backupJson,
  Map<String, dynamic> deviceSettings,
) {
  final decoded = jsonDecode(backupJson) as Map<String, dynamic>;
  final settings = decoded['settings'];
  if (settings is Map<String, dynamic>) {
    decoded['settings'] = filterCloudCredsForImport(settings, deviceSettings);
  }
  return jsonEncode(decoded);
}
