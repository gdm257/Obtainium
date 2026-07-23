import 'dart:convert';
import 'dart:typed_data';

/// Kinds of cloud storage providers supported by the cloud export/import feature.
enum CloudProviderKind { s3, webdav }

/// A remote file listed from a cloud target. Files are identified by name and
/// may carry a last-modified timestamp so callers can sort by recency.
class RemoteFile {
  final String filename;
  final DateTime? lastModified;

  const RemoteFile({required this.filename, this.lastModified});

  @override
  String toString() => 'RemoteFile($filename${lastModified != null ? ', $lastModified' : ''})';
}

/// A configured, usable cloud target: its kind plus the credentials backing it.
/// Targets are derived from non-empty credentials, never persisted directly.
class CloudTarget {
  final CloudProviderKind kind;
  final String label;

  const CloudTarget({required this.kind, required this.label});

  @override
  String toString() => 'CloudTarget(${kind.name}: $label)';
}

/// S3 (and S3-compatible: MinIO/R2/B2/…) connection parameters.
///
/// Stored plaintext in prefs under `s3-creds` as a JSON string, following the
/// existing `-creds` secret convention (auto-exported / auto-restored when
/// "include settings" = all).
class S3Creds {
  /// Base endpoint including scheme and port, e.g. `https://s3.us-east-1.amazonaws.com`
  /// or `https://minio.example.local:9000`. Must not include the bucket.
  final String endpoint;

  /// Bucket (and optional key prefix) to store export files under.
  final String bucket;

  /// AWS region, e.g. `us-east-1`. Also used as the SigV4 region scope.
  final String region;

  final String accessKey;
  final String secretKey;

  /// When true, use path-style addressing (`host/bucket/key`) — required by
  /// MinIO/R2/B2 and most self-hosted S3 servers. When false, use virtual-host
  /// style (`bucket.host/key`).
  final bool pathStyle;

  /// Optional key prefix inside the bucket (no leading slash).
  final String prefix;

  const S3Creds({
    required this.endpoint,
    required this.bucket,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    this.pathStyle = true,
    this.prefix = '',
  });

  bool get isValid =>
      endpoint.trim().isNotEmpty &&
      bucket.trim().isNotEmpty &&
      region.trim().isNotEmpty &&
      accessKey.trim().isNotEmpty &&
      secretKey.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'endpoint': endpoint,
        'bucket': bucket,
        'region': region,
        'accessKey': accessKey,
        'secretKey': secretKey,
        'pathStyle': pathStyle,
        'prefix': prefix,
      };

  factory S3Creds.fromJson(Map<String, dynamic> json) => S3Creds(
        endpoint: json['endpoint'] as String? ?? '',
        bucket: json['bucket'] as String? ?? '',
        region: json['region'] as String? ?? '',
        accessKey: json['accessKey'] as String? ?? '',
        secretKey: json['secretKey'] as String? ?? '',
        pathStyle: json['pathStyle'] as bool? ?? true,
        prefix: json['prefix'] as String? ?? '',
      );

  /// Serialize to a single string for prefs storage (see `-creds` convention).
  String toJsonString() => jsonEncode(toJson());

  static S3Creds? fromJsonString(String? json) =>
      json == null || json.isEmpty ? null : S3Creds.fromJson(jsonDecode(json) as Map<String, dynamic>);

  /// Normalized endpoint with any trailing slash removed, no bucket.
  Uri get endpointUri => Uri.parse(endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint);

  /// Path-style bucket+prefix segment, e.g. `mybucket` or `mybucket/prefix`.
  String get bucketPrefixPath {
    final b = bucket.startsWith('/') ? bucket.substring(1) : bucket;
    return prefix.isEmpty ? b : '$b/${prefix.replaceAll(RegExp(r'^/+|/+$'), '')}';
  }

  /// Short human-readable label for target selection menus.
  String get label => '${endpointUri.host}/$bucket';

  @override
  String toString() => 'S3Creds($label)';
}

/// WebDAV connection parameters.
///
/// Stored plaintext in prefs under `webdav-creds` as a JSON string (see
/// `-creds` convention). [url] is the collection URL exports are written into
/// and listed from.
class WebDAVCreds {
  final String url;
  final String username;
  final String password;

  const WebDAVCreds({
    required this.url,
    required this.username,
    required this.password,
  });

  bool get isValid =>
      url.trim().isNotEmpty && username.trim().isNotEmpty && password.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'url': url,
        'username': username,
        'password': password,
      };

  factory WebDAVCreds.fromJson(Map<String, dynamic> json) => WebDAVCreds(
        url: json['url'] as String? ?? '',
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
      );

  String toJsonString() => jsonEncode(toJson());

  static WebDAVCreds? fromJsonString(String? json) => json == null || json.isEmpty
      ? null
      : WebDAVCreds.fromJson(jsonDecode(json) as Map<String, dynamic>);

  /// Collection URL with any trailing slash normalized away.
  Uri get collectionUri {
    final u = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    return Uri.parse(u);
  }

  String get label => collectionUri.host;

  @override
  String toString() => 'WebDAVCreds($label)';
}

/// Unified transport interface for S3 / WebDAV. Implementations own a concrete
/// set of credentials and perform the three operations backing cloud
/// export/import.
abstract class CloudStorage {
  /// Upload a file under [filename], keeping history: implementations must not
  /// overwrite an existing object of the same name (export filenames embed a
  /// timestamp, so collisions imply re-upload of the same content).
  Future<void> upload(String filename, Uint8List bytes);

  /// List remote export files, newest-first when a timestamp is available.
  Future<List<RemoteFile>> list();

  /// Download [filename] and return its raw JSON body as a string, ready for
  /// [AppsProvider.import].
  Future<String> download(String filename);
}
