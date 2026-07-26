import 'dart:convert';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart' as http;

import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/services/cloud_backup/cloud_backup_helpers.dart';
import 'package:obtainium/services/cloud_backup/cloud_backup_prefs.dart';
import 'package:obtainium/services/cloud_backup/s3_client.dart';
import 'package:obtainium/services/cloud_backup/webdav_client.dart';

/// Glue between the app's providers and the backend-agnostic
/// [CloudBackupService]. Owns no logic of its own: the filename shape, the
/// creds conflict rule, and the HTTP/signing math all live in tested units;
/// this class only composes them.
///
/// Export reuses [AppsProvider.generateExportJSON] unchanged and uploads the
/// result under a timestamped name. Import downloads a backup, applies the
/// creds import rule, and hands the (possibly filtered) JSON back so the host
/// page can run the existing local-import flow verbatim.
class CloudBackupActions {
  CloudBackupActions(
    this.apps,
    this.settings, {
    http.Client? httpClient,
    CloudBackupService? service,
  })  : _service = service ??
            CloudBackupService(
              S3Client(httpClient ?? http.Client()),
              WebDavClient(httpClient ?? http.Client()),
            );

  final AppsProvider apps;
  final SettingsProvider settings;
  final CloudBackupService _service;

  /// The current cloud-backup configuration, read from prefs.
  CloudBackupConfig get config =>
      cloudBackupConfigFromPrefs(settings.getSettingString);

  /// Whether a backend is selected (regardless of whether it's fully filled in).
  bool get hasActiveBackend => config.active != CloudBackend.none;

  /// Generates the export JSON (same as the local export) and uploads it to the
  /// active backend under a timestamped name. Returns the uploaded filename.
  Future<String> exportToCloud() async {
    final cfg = config;
    final exportMap = apps.generateExportJSON(sp: settings);
    const encoder = JsonEncoder.withIndent('    ');
    final bytes =
        Uint8List.fromList(utf8.encode(encoder.convert(exportMap)));
    final filename = cloudBackupFileName(
      prefix: tr('obtainiumExportHyphenatedLowercase'),
      at: DateTime.now(),
    );
    await _service.upload(cfg, filename: filename, bytes: bytes);
    return filename;
  }

  /// Lists backup files available on the active backend.
  Future<List<CloudBackupEntry>> listBackups() => _service.list(config);

  /// Downloads [entry], applies the creds import rule against the device's
  /// current cloud secrets, and returns the JSON string ready for the existing
  /// [AppsProvider.import] path.
  Future<String> downloadForImport(CloudBackupEntry entry) async {
    final cfg = config;
    final bytes = await _service.download(cfg, entry);
    final raw = utf8.decode(bytes);
    final deviceCreds = <String, dynamic>{
      for (final k in cloudBackupCredsKeys) k: settings.getSettingString(k) ?? '',
    };
    return applyCredsImportRule(raw, deviceCreds);
  }
}