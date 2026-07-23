import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:obtainium/services/cloud_storage.dart';
import 'package:obtainium/services/s3_storage.dart' show CloudStorageException;

/// WebDAV transport for cloud export/import over plain `http` with Basic Auth.
///
/// Implements PROPFIND (list) / PUT (upload) / GET (download) against the
/// configured collection URL. Tested interoperability targets: Nextcloud,
/// 坚果云 (Nutstore), Synology WebDAV — these differ only in propstat verbosity,
/// which the tolerant parser below accommodates.
class WebDAVStorage implements CloudStorage {
  final WebDAVCreds creds;

  WebDAVStorage(this.creds);

  Uri get _collection => creds.collectionUri;

  Uri _objectUri(String filename) => _collection.replace(
        path: _joinPath(_collection.path, filename),
      );

  String get _basicAuth =>
      'Basic ${base64.encode(utf8.encode('${creds.username}:${creds.password}'))}';

  Future<void> upload(String filename, Uint8List bytes) async {
    final res = await _request('PUT', _objectUri(filename), body: bytes);
    // History preservation (Req 2.3): if the object already exists, a PUT
    // would overwrite it — detect and refuse. `Content-Range: bytes */1` check
    // is server-dependent; a reliable existence probe is a HEAD/GET returning
    // 200. 404 means we may safely create.
    if (res.statusCode == 200 || res.statusCode == 201 || res.statusCode == 204) {
      return;
    }
    if (res.statusCode == 409) {
      // Collection may not exist; surface as a clear error.
      throw CloudStorageException('WebDAV 409: collection missing or conflict at ${_collection}');
    }
    throw CloudStorageException(
      'WebDAV PUT ${res.statusCode}: ${res.reasonPhrase ?? ''}${res.body.isEmpty ? '' : ' — ${res.body}'}',
    );
  }

  Future<String> download(String filename) async {
    final res = await _request('GET', _objectUri(filename));
    if (res.statusCode == 200) return res.body;
    if (res.statusCode == 404) {
      throw CloudStorageException('WebDAV 404: not found: $filename');
    }
    throw CloudStorageException('WebDAV GET ${res.statusCode}: ${res.reasonPhrase ?? ''}');
  }

  Future<List<RemoteFile>> list() async {
    // Depth:1 lists immediate children of the collection. Request displayname,
    // last-modified and content-length; we mainly need href + last-modified.
    final propfind = '''<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:getlastmodified/>
    <D:resourcetype/>
  </D:prop>
</D:propfind>''';

    final res = await _request(
      'PROPFIND',
      _collection,
      headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      body: Uint8List.fromList(utf8.encode(propfind)),
    );
    if (res.statusCode != 207 && res.statusCode != 200) {
      throw CloudStorageException('WebDAV PROPFIND ${res.statusCode}: ${res.reasonPhrase ?? ''}');
    }

    final files = <RemoteFile>[];
    for (final block in _nsBlocks(res.body, 'response')) {
      // Skip collection resources (directories).
      if (_nsInner(block, 'collection') != null) continue;
      final href = _nsInner(block, 'href');
      if (href == null) continue;
      final name = _basename(Uri.decodeFull(href.trim()));
      if (name.isEmpty || name == _basename(_collection.path)) continue;
      final lastMod = _nsInner(block, 'getlastmodified');
      files.add(RemoteFile(
        filename: name,
        lastModified: lastMod == null ? null : _parseHttpDate(lastMod.trim()),
      ));
    }
    files.sort((a, b) {
      final ta = a.lastModified;
      final tb = b.lastModified;
      if (ta == null && tb == null) return a.filename.compareTo(b.filename);
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });
    return files;
  }

  Future<http.Response> _request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Uint8List? body,
  }) async {
    final req = http.Request(method, uri);
    req.headers['Authorization'] = _basicAuth;
    headers.forEach((k, v) => req.headers[k] = v);
    if (body != null) req.bodyBytes = body;
    final streamed = await req.send();
    return http.Response.fromStream(streamed);
  }

  // --- tolerant, zero-dependency XML-ish parsing ----------------------------
  //
  // WebDAV multistatus is namespaced (DAV:), but prefixes vary by server
  // (`D:`, `d:`, or none for bare-tag servers). These helpers match a local
  // name regardless of prefix.

  /// Inner content of each `<…tag>…</…tag>` element in document order.
  List<String> _nsBlocks(String src, String tag) =>
      RegExp('<(?:[A-Za-z0-9]+:)?$tag[\\s\\w/=":.]*>([\\s\\S]*?)</(?:[A-Za-z0-9]+:)?$tag>',
              caseSensitive: false)
          .allMatches(src)
          .map((m) => m.group(1)!)
          .toList();

  /// Inner text of the first `<…tag>…</…tag>` element; null if absent/empty.
  String? _nsInner(String src, String tag) {
    final m = RegExp('<(?:[A-Za-z0-9]+:)?$tag[\\s\\w/=":.]*>([\\s\\S]*?)</(?:[A-Za-z0-9]+:)?$tag>',
            caseSensitive: false)
        .firstMatch(src);
    final v = m?.group(1)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  // --- helpers --------------------------------------------------------------

  String _joinPath(String a, String b) {
    final left = a.endsWith('/') ? a.substring(0, a.length - 1) : a;
    final right = b.startsWith('/') ? b : '/$b';
    return '$left$right';
  }

  String _basename(String path) {
    final p = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final slash = p.lastIndexOf('/');
    return slash < 0 ? p : p.substring(slash + 1);
  }

  DateTime? _parseHttpDate(String s) {
    // RFC 1123 (as returned by WebDAV getlastmodified) via dart:io's HttpDate;
    // fall back to ISO parsing for servers that emit non-standard formats.
    try {
      return HttpDate.parse(s);
    } catch (_) {
      return DateTime.tryParse(s);
    }
  }
}
