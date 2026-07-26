import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/services/cloud_backup/cloud_backup_prefs.dart';

/// Dialog to configure the cloud-backup backends (S3 / WebDAV) and pick the
/// active one. Reads the current config from prefs, edits in memory, and writes
/// every field back via [SettingsProvider.setSettingString] on save — so the
/// same prefs flow through the existing export/import (secrets under `-creds`
/// keys are recognized automatically). Self-contained: no dependency on the
/// settings page's dense input decorations.
class CloudBackupConfigDialog extends StatefulWidget {
  const CloudBackupConfigDialog({super.key, required this.settings});

  final SettingsProvider settings;

  @override
  State<CloudBackupConfigDialog> createState() =>
      _CloudBackupConfigDialogState();

  /// Convenience wrapper around [showDialog] that returns true when the user
  /// saved changes.
  static Future<bool?> show(BuildContext context, SettingsProvider settings) {
    return showDialog<bool>(
      context: context,
      builder: (_) => CloudBackupConfigDialog(settings: settings),
    );
  }
}

class _CloudBackupConfigDialogState extends State<CloudBackupConfigDialog> {
  late final CloudBackupConfig _cfg;
  late final Map<String, TextEditingController> _c;
  late CloudBackend _active;

  @override
  void initState() {
    super.initState();
    _cfg = cloudBackupConfigFromPrefs(widget.settings.getSettingString);
    _active = _cfg.active;
    final fields = {
      's3Endpoint': _cfg.s3Endpoint,
      's3Bucket': _cfg.s3Bucket,
      's3Region': _cfg.s3Region.isEmpty ? 'us-east-1' : _cfg.s3Region,
      's3Prefix': _cfg.s3Prefix,
      's3AccessKey': _cfg.s3AccessKey,
      's3Secret': _cfg.s3SecretKey,
      'webdavBaseUrl': _cfg.webdavBaseUrl,
      'webdavPrefix': _cfg.webdavPrefix,
      'webdavUsername': _cfg.webdavUsername,
      'webdavPassword': _cfg.webdavPassword,
    };
    _c = {
      for (final e in fields.entries)
        e.key: TextEditingController(text: e.value),
    };
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final updated = CloudBackupConfig(
      active: _active,
      s3Endpoint: _c['s3Endpoint']!.text.trim(),
      s3Bucket: _c['s3Bucket']!.text.trim(),
      s3Region: _c['s3Region']!.text.trim(),
      s3Prefix: _c['s3Prefix']!.text.trim(),
      s3AccessKey: _c['s3AccessKey']!.text.trim(),
      s3SecretKey: _c['s3Secret']!.text.trim(),
      webdavBaseUrl: _c['webdavBaseUrl']!.text.trim(),
      webdavPrefix: _c['webdavPrefix']!.text.trim(),
      webdavUsername: _c['webdavUsername']!.text.trim(),
      webdavPassword: _c['webdavPassword']!.text.trim(),
    );
    saveCloudBackupConfig(widget.settings.setSettingString, updated);
    Navigator.of(context).pop(true);
  }

  Widget _field(
    String key, {
    required String label,
    bool obscure = false,
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: _c[key],
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('cloudBackupConfigTitle')),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<CloudBackend>(
                initialValue: _active,
                decoration: InputDecoration(
                  labelText: tr('cloudBackupActiveBackend'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  DropdownMenuItem(
                    value: CloudBackend.none,
                    child: Text(tr('cloudBackendNone')),
                  ),
                  const DropdownMenuItem(
                    value: CloudBackend.s3,
                    child: Text('S3'),
                  ),
                  const DropdownMenuItem(
                    value: CloudBackend.webdav,
                    child: Text('WebDAV'),
                  ),
                ],
                onChanged: (v) => setState(() => _active = v ?? CloudBackend.none),
              ),
              const SizedBox(height: 12),
              Text('S3', style: Theme.of(context).textTheme.titleSmall),
              _field('s3Endpoint', label: tr('cloudBackupS3Endpoint'),
                  hint: 'https://s3.us-east-1.amazonaws.com'),
              _field('s3Bucket', label: tr('cloudBackupS3Bucket')),
              _field('s3Region', label: tr('cloudBackupS3Region')),
              _field('s3Prefix', label: tr('cloudBackupPrefix'),
                  hint: 'backups/'),
              _field('s3AccessKey', label: tr('cloudBackupS3AccessKey')),
              _field('s3Secret',
                  label: tr('cloudBackupS3Secret'), obscure: true),
              const SizedBox(height: 12),
              Text('WebDAV', style: Theme.of(context).textTheme.titleSmall),
              _field('webdavBaseUrl', label: tr('cloudBackupWebDavUrl'),
                  hint: 'https://dav.example.com/dav/'),
              _field('webdavPrefix', label: tr('cloudBackupPrefix'),
                  hint: 'backups/'),
              _field('webdavUsername', label: tr('cloudBackupWebDavUser')),
              _field('webdavPassword',
                  label: tr('cloudBackupWebDavPassword'), obscure: true),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(onPressed: _save, child: Text(tr('save'))),
      ],
    );
  }
}