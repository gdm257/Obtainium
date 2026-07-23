import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:obtainium/services/cloud_storage.dart';
import 'package:obtainium/services/sig_v4.dart';

/// S3 (and S3-compatible) transport for cloud export/import.
///
/// Implements PutObject / GetObject / ListObjectsV2 over plain `http`, signed
/// with AWS Signature V4 ([signSigV4]). No AWS SDK is used.
class S3Storage implements CloudStorage {
  final S3Creds creds;

  S3Storage(this.creds);

  /// Build the request URI for [objectKey] (may be empty for the bucket root,
  /// used by ListObjectsV2). Addresses path-style or virtual-host style per
  /// [S3Creds.pathStyle].
  Uri _uri({String objectKey = '', Map<String, dynamic>? query}) {
    final base = creds.endpointUri;
    final key = objectKey.isEmpty
        ? creds.bucketPrefixPath
        : '${creds.bucketPrefixPath}/${objectKey}';
    final host = creds.pathStyle
        ? base.host
        : '${creds.bucket}.${base.host}';
    final port = base.hasPort &&
            !((base.scheme == 'http' && base.port == 80) ||
                (base.scheme == 'https' && base.port == 443))
        ? base.port
        : null;
    return base.replace(host: host, port: port, path: '/$key', queryParameters: query);
  }

  Future<void> upload(String filename, Uint8List bytes) async {
    // History preservation (Req 2.3): refuse to overwrite an existing object.
    if (await _exists(filename)) {
      throw CloudStorageException('Remote file already exists: $filename (history preserved)');
    }
    final res = await _send('PUT', filename, bytes);
    _ensureSuccess(res, 200);
  }

  Future<String> download(String filename) async {
    final res = await _send('GET', filename, Uint8List(0));
    _ensureSuccess(res, 200);
    return res.body;
  }

  Future<List<RemoteFile>> list() async {
    // ListObjectsV2 on the bucket (+prefix), limit 1000 keys per request.
    // ponytail: no pagination loop — export history well under 1000 files is
    // the expected case; if it grows, switch to a continuation-token loop.
    final uri = _uri(query: {
      'list-type': '2',
      if (creds.prefix.isNotEmpty) 'prefix': creds.prefix,
      'max-keys': '1000',
    });
    final res = await _sendRaw('GET', uri, Uint8List(0));
    _ensureSuccess(res, 200);

    // Minimal parse: split on <Contents>…</Contents> blocks and read inner
    // tags by substring. Avoids pulling in an XML package (zero-new-deps).
    final files = <RemoteFile>[];
    for (final block in _tagBlocks(res.body, 'Contents')) {
      final name = _innerTag(block, 'Key');
      if (name == null) continue;
      // Key may include the configured prefix; strip it for display.
      final display = creds.prefix.isNotEmpty && name.startsWith('${creds.prefix}/')
          ? name.substring(creds.prefix.length + 1)
          : name;
      if (display.isEmpty) continue;
      final lastMod = _innerTag(block, 'LastModified');
      files.add(RemoteFile(
        filename: display,
        lastModified: lastMod == null ? null : DateTime.tryParse(lastMod),
      ));
    }
    files.sort((a, b) {
      final ta = a.lastModified;
      final tb = b.lastModified;
      if (ta == null && tb == null) return a.filename.compareTo(b.filename);
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta); // newest first
    });
    return files;
  }

  /// HEAD is unsigned-GET friendly but some S3 servers mishandle HEAD auth;
  /// use a signed GET with range 0-0 as a cheap existence probe.
  Future<bool> _exists(String filename) async {
    final uri = _uri(objectKey: filename);
    final res = await _sendRaw('GET', uri, Uint8List(0), extra: {'Range': 'bytes=0-0'});
    if (res.statusCode == 200 || res.statusCode == 206) return true;
    if (res.statusCode == 404) return false;
    _ensureSuccess(res, 200);
    return true;
  }

  Future<http.Response> _send(String method, String objectKey, Uint8List body,
      {Map<String, String> extra = const {}}) async {
    return _sendRaw(method, _uri(objectKey: objectKey), body, extra: extra);
  }

  Future<http.Response> _sendRaw(String method, Uri uri, Uint8List body,
      {Map<String, String> extra = const {}}) async {
    final amzDate = _amzDate(DateTime.now().toUtc());
    final signed = signSigV4(
      method: method,
      uri: uri,
      region: creds.region,
      service: 's3',
      accessKey: creds.accessKey,
      secretKey: creds.secretKey,
      body: body,
      amzDate: amzDate,
      extraHeaders: extra,
    );
    final req = http.Request(method, uri)
      ..bodyBytes = body
      ..headers['Authorization'] = signed.authorization;
    signed.headers.forEach((k, v) => req.headers[k] = v);
    extra.forEach((k, v) => req.headers[k] = v);
    final streamed = await req.send();
    return http.Response.fromStream(streamed);
  }

  void _ensureSuccess(http.Response res, int expected) {
    if (res.statusCode == expected) return;
    final detail = _extractS3Error(res.body) ?? res.body;
    throw CloudStorageException(
      'S3 ${res.statusCode}: ${res.reasonPhrase ?? ''}${detail.isEmpty ? '' : ' — $detail'}',
    );
  }

  String? _extractS3Error(String body) {
    final code = _innerTag(body, 'Code');
    final msg = _innerTag(body, 'Message');
    if (code != null) return msg == null ? code : '$code: $msg';
    return null;
  }

  /// Text between `<name>…</name>` (first match, trimmed); null if absent/empty.
  String? _innerTag(String src, String name) {
    final open = src.indexOf('<$name>');
    if (open < 0) return null;
    final close = src.indexOf('</$name>', open);
    if (close < 0) return null;
    final value = src.substring(open + name.length + 2, close).trim();
    return value.isEmpty ? null : value;
  }

  /// Substrings of [src] wrapped in `<tag>…</tag>` blocks, in document order.
  List<String> _tagBlocks(String src, String tag) {
    final blocks = <String>[];
    final open = '<$tag>';
    final close = '</$tag>';
    var i = 0;
    while (true) {
      final start = src.indexOf(open, i);
      if (start < 0) break;
      final end = src.indexOf(close, start);
      if (end < 0) break;
      blocks.add(src.substring(start + open.length, end));
      i = end + close.length;
    }
    return blocks;
  }

  /// AWS date format: `yyyyMMddTHHmmssZ`.
  String _amzDate(DateTime t) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${p(t.month)}${p(t.day)}T${p(t.hour)}${p(t.minute)}${p(t.second)}Z';
  }
}

/// Error raised by cloud transports, surfaced to the user via the existing
/// `showError` flow. Kept here (not in custom_errors.dart) to avoid touching a
/// shared upstream-owned file.
class CloudStorageException implements Exception {
  final String message;
  CloudStorageException(this.message);
  @override
  String toString() => message;
}
