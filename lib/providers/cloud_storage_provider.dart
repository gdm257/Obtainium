import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/services/cloud_storage.dart';
import 'package:obtainium/services/s3_storage.dart';
import 'package:obtainium/services/webdav_storage.dart';

/// In-memory fake transport for unit testing orchestration. Stores uploads by
/// filename and never overwrites, mirroring the real transports' contracts.
class FakeCloudStorage implements CloudStorage {
  final Map<String, Uint8List> _store = {};
  final Map<String, DateTime> _times = {};

  @override
  Future<void> upload(String filename, Uint8List bytes) async {
    if (_store.containsKey(filename)) {
      throw CloudStorageException('Remote file already exists: $filename');
    }
    _store[filename] = bytes;
    _times[filename] = DateTime.utc(2024, 1, 1).add(Duration(seconds: _store.length));
  }

  @override
  Future<String> download(String filename) async {
    final b = _store[filename];
    if (b == null) throw CloudStorageException('404: $filename');
    return String.fromCharCodes(b);
  }

  @override
  Future<List<RemoteFile>> list() async {
    final files = _store.keys
        .map((n) => RemoteFile(filename: n, lastModified: _times[n]))
        .toList();
    files.sort((a, b) => (b.lastModified ?? DateTime.fromMillisecondsSinceEpoch(0))
        .compareTo(a.lastModified ?? DateTime.fromMillisecondsSinceEpoch(0)));
    return files;
  }
}

/// Owns cloud-export/import credentials, derives the list of configured
/// targets, and orchestrates upload/list/download through the matching
/// [CloudStorage] transport.
///
/// Credentials are persisted plaintext under the existing `-creds` prefs
/// convention (`s3-creds` / `webdav-creds`), so they auto-export when "include
/// settings" = all and auto-restore on import — no schema change.
class CloudStorageProvider extends ChangeNotifier {
  final SettingsProvider settingsProvider;

  CloudStorageProvider({required this.settingsProvider});

  /// Test-only override mapping target label → fake transport. When set,
  /// [transportFor] returns the fake for a matching label instead of building
  /// the real S3/WebDAV client. Enables offline orchestration tests.
  @visibleForTesting
  final Map<String, CloudStorage> transportOverrides = {};

  static const _s3CredsKey = 's3-creds';
  static const _webdavCredsKey = 'webdav-creds';

  S3Creds? get s3Creds => S3Creds.fromJsonString(settingsProvider.getSettingString(_s3CredsKey));

  set s3Creds(S3Creds? v) {
    if (v == null || !v.isValid) {
      settingsProvider.prefs?.remove(_s3CredsKey);
    } else {
      settingsProvider.setSettingString(_s3CredsKey, v.toJsonString());
    }
    notifyListeners();
  }

  WebDAVCreds? get webdavCreds =>
      WebDAVCreds.fromJsonString(settingsProvider.getSettingString(_webdavCredsKey));

  set webdavCreds(WebDAVCreds? v) {
    if (v == null || !v.isValid) {
      settingsProvider.prefs?.remove(_webdavCredsKey);
    } else {
      settingsProvider.setSettingString(_webdavCredsKey, v.toJsonString());
    }
    notifyListeners();
  }

  /// Configured, usable cloud targets, derived from non-empty credentials.
  /// Order: S3 first, then WebDAV — stable for UI menus.
  List<CloudTarget> get availableTargets {
    final targets = <CloudTarget>[];
    final s3 = s3Creds;
    if (s3 != null && s3.isValid) {
      targets.add(CloudTarget(kind: CloudProviderKind.s3, label: s3.label));
    }
    final webdav = webdavCreds;
    if (webdav != null && webdav.isValid) {
      targets.add(CloudTarget(kind: CloudProviderKind.webdav, label: webdav.label));
    }
    return targets;
  }

  bool get hasAnyTarget => availableTargets.isNotEmpty;

  /// Resolve a target to its concrete transport. Throws if the target's
  /// credentials are missing/invalid (caller should guard with
  /// [availableTargets]). Returns a test override when one is registered for
  /// the target's label.
  @visibleForTesting
  CloudStorage transportFor(CloudTarget target) {
    final override = transportOverrides[target.label];
    if (override != null) return override;
    switch (target.kind) {
      case CloudProviderKind.s3:
        final c = s3Creds;
        if (c == null || !c.isValid) {
          throw CloudStorageException('S3 target not configured');
        }
        return S3Storage(c);
      case CloudProviderKind.webdav:
        final c = webdavCreds;
        if (c == null || !c.isValid) {
          throw CloudStorageException('WebDAV target not configured');
        }
        return WebDAVStorage(c);
    }
  }

  /// Upload [filename] to the single selected [target], preserving history
  /// (the transport refuses to overwrite).
  Future<void> upload(CloudTarget target, String filename, Uint8List bytes) =>
      transportFor(target).upload(filename, bytes);

  /// List historical export files on [target], newest-first.
  Future<List<RemoteFile>> list(CloudTarget target) => transportFor(target).list();

  /// Download [filename] from [target]; returns JSON ready for
  /// `AppsProvider.import`.
  Future<String> download(CloudTarget target, String filename) =>
      transportFor(target).download(filename);
}
