import 'dart:typed_data';

import 'package:obtainium/services/cloud_backup/s3_client.dart';
import 'package:obtainium/services/cloud_backup/webdav_client.dart';

/// Which cloud backend a backup operation targets. [none] means no backend is
/// selected and any backup/import attempt throws [CloudBackupConfigException].
enum CloudBackend { none, s3, webdav }

/// Thrown when the active backend isn't configured (no backend selected, or the
/// selected backend is missing required fields). Distinct from transport errors
/// ([S3Exception]/[WebDavException]) so the UI can guide setup vs. show a
/// network error.
class CloudBackupConfigException implements Exception {
  CloudBackupConfigException(this.message);
  final String message;
  @override
  String toString() => 'CloudBackupConfigException: $message';
}

/// A snapshot of the cloud-backup prefs needed to talk to a backend. Read from
/// SharedPreferences by the host (SettingsProvider) and handed to the service;
/// keeping it a plain value lets the dispatch logic stay unit-testable without
/// a prefs/Flutter binding.
class CloudBackupConfig {
  const CloudBackupConfig({
    this.active = CloudBackend.none,
    this.s3Endpoint = '',
    this.s3Bucket = '',
    this.s3Region = '',
    this.s3Prefix = '',
    this.s3AccessKey = '',
    this.s3SecretKey = '',
    this.webdavBaseUrl = '',
    this.webdavPrefix = '',
    this.webdavUsername = '',
    this.webdavPassword = '',
  });

  final CloudBackend active;

  // S3 (path-style)
  final String s3Endpoint;
  final String s3Bucket;
  final String s3Region;
  final String s3Prefix;
  final String s3AccessKey;
  final String s3SecretKey;

  // WebDAV
  final String webdavBaseUrl;
  final String webdavPrefix;
  final String webdavUsername;
  final String webdavPassword;
}

/// One file listed on the active backend. [name] is for display (basename),
/// [ref] is the opaque handle to pass back to [CloudBackupService.download].
class CloudBackupEntry {
  const CloudBackupEntry({required this.name, required this.ref});
  final String name;
  final String ref;
}

/// Façade over [S3Client]/[WebDavClient]: picks the active backend, composes the
/// object key / URL, and normalizes listings into display name + fetch handle.
/// Upload uses a caller-chosen filename (timestamped, like the local export) so
/// versions never overwrite; download/list target the active backend only.
class CloudBackupService {
  CloudBackupService(this.s3, this.webdav);

  final S3Client s3;
  final WebDavClient webdav;

  /// Uploads [bytes] under [filename] on the active backend.
  Future<void> upload(
    CloudBackupConfig cfg, {
    required String filename,
    required Uint8List bytes,
  }) async {
    switch (cfg.active) {
      case CloudBackend.s3:
        _requireS3(cfg);
        await s3.putObject(
          endpoint: Uri.parse(cfg.s3Endpoint),
          bucket: cfg.s3Bucket,
          region: cfg.s3Region,
          objectKey: '${cfg.s3Prefix}$filename',
          body: bytes,
          accessKey: cfg.s3AccessKey,
          secretKey: cfg.s3SecretKey,
        );
      case CloudBackend.webdav:
        _requireWebDav(cfg);
        await webdav.putFile(
          url: _webdavFileUrl(cfg, filename),
          body: bytes,
          username: cfg.webdavUsername,
          password: cfg.webdavPassword,
        );
      case CloudBackend.none:
        throw CloudBackupConfigException('No cloud backup backend is active.');
    }
  }

  /// Lists backup files on the active backend.
  Future<List<CloudBackupEntry>> list(CloudBackupConfig cfg) async {
    switch (cfg.active) {
      case CloudBackend.s3:
        _requireS3(cfg);
        final keys = await s3.listObjects(
          endpoint: Uri.parse(cfg.s3Endpoint),
          bucket: cfg.s3Bucket,
          region: cfg.s3Region,
          prefix: cfg.s3Prefix,
          accessKey: cfg.s3AccessKey,
          secretKey: cfg.s3SecretKey,
        );
        return keys.map((k) => CloudBackupEntry(name: _basename(k), ref: k)).toList();
      case CloudBackend.webdav:
        _requireWebDav(cfg);
        final hrefs = await webdav.listFiles(
          collectionUrl: _webdavCollectionUrl(cfg),
          username: cfg.webdavUsername,
          password: cfg.webdavPassword,
        );
        return hrefs.map((h) => CloudBackupEntry(name: _basename(h), ref: h)).toList();
      case CloudBackend.none:
        throw CloudBackupConfigException('No cloud backup backend is active.');
    }
  }

  /// Downloads the file described by [entry] from the active backend.
  Future<Uint8List> download(CloudBackupConfig cfg, CloudBackupEntry entry) async {
    switch (cfg.active) {
      case CloudBackend.s3:
        _requireS3(cfg);
        return s3.getObject(
          endpoint: Uri.parse(cfg.s3Endpoint),
          bucket: cfg.s3Bucket,
          region: cfg.s3Region,
          objectKey: entry.ref,
          accessKey: cfg.s3AccessKey,
          secretKey: cfg.s3SecretKey,
        );
      case CloudBackend.webdav:
        _requireWebDav(cfg);
        // WebDAV refs are absolute server paths; resolve against the base host.
        return webdav.getFile(
          url: Uri.parse(cfg.webdavBaseUrl).resolveUri(Uri.parse(entry.ref)),
          username: cfg.webdavUsername,
          password: cfg.webdavPassword,
        );
      case CloudBackend.none:
        throw CloudBackupConfigException('No cloud backup backend is active.');
    }
  }

  void _requireS3(CloudBackupConfig cfg) {
    if (cfg.s3Endpoint.isEmpty ||
        cfg.s3Bucket.isEmpty ||
        cfg.s3AccessKey.isEmpty ||
        cfg.s3SecretKey.isEmpty) {
      throw CloudBackupConfigException('S3 backend is not fully configured.');
    }
  }

  void _requireWebDav(CloudBackupConfig cfg) {
    if (cfg.webdavBaseUrl.isEmpty) {
      throw CloudBackupConfigException('WebDAV backend is not fully configured.');
    }
  }

  /// `<baseUrl>/<prefix>` as a collection URL, robust to missing/extra slashes.
  Uri _webdavCollectionUrl(CloudBackupConfig cfg) {
    final base = Uri.parse(cfg.webdavBaseUrl);
    final prefix = cfg.webdavPrefix.isEmpty ? '' : cfg.webdavPrefix;
    final withSlash = prefix.endsWith('/') ? prefix : '$prefix/';
    return base.resolveUri(Uri.parse(withSlash));
  }

  /// `<baseUrl>/<prefix>/<filename>`.
  Uri _webdavFileUrl(CloudBackupConfig cfg, String filename) =>
      _webdavCollectionUrl(cfg).resolveUri(Uri.parse(filename));

  /// Last path segment of [s] (after the final `/`), URL-decoded. For a path
  /// with no slash, [s] itself.
  static String _basename(String s) {
    final decoded = Uri.decodeFull(s);
    final i = decoded.lastIndexOf('/');
    return i < 0 ? decoded : decoded.substring(i + 1);
  }
}