import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Thrown when a WebDAV request returns a non-2xx status.
class WebDavException implements Exception {
  WebDavException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => 'WebDavException($statusCode): $message';
}

/// Minimal WebDAV client over plain HTTP: PUT to upload, GET to download,
/// PROPFIND to list a collection. Uses HTTP Basic auth when credentials are
/// supplied (matches Nextcloud/ownCloud/nginx/Apache WebDAV defaults). No XML
/// dependency: the PROPFIND multistatus response is scanned for `<href>` tags,
/// which is robust across namespace prefixes (`d:`, `D:`, none).
///
/// The HTTP client is injected so tests drive it with a recording fake.
class WebDavClient {
  WebDavClient(this.httpClient);

  final http.Client httpClient;

  /// Uploads [body] to [url]. Overwrites if the resource already exists.
  Future<void> putFile({
    required Uri url,
    required Uint8List body,
    String? username,
    String? password,
  }) async {
    final resp = await _send(
      method: 'PUT',
      url: url,
      body: body,
      username: username,
      password: password,
    );
    _ensureOk(resp, 'PUT $url');
  }

  /// Downloads [url] and returns its bytes.
  Future<Uint8List> getFile({
    required Uri url,
    String? username,
    String? password,
  }) async {
    final resp = await _send(
      method: 'GET',
      url: url,
      username: username,
      password: password,
    );
    _ensureOk(resp, 'GET $url');
    return Uint8List.fromList(await resp.stream.toBytes());
  }

  /// Lists the resources inside [collectionUrl] via PROPFIND (Depth: 1).
  /// Returns the decoded `href` of each non-collection resource, in the order
  /// the server reports them. The collection itself (href ending in `/`) is
  /// skipped so callers only see files.
  Future<List<String>> listFiles({
    required Uri collectionUrl,
    String? username,
    String? password,
  }) async {
    final resp = await _send(
      method: 'PROPFIND',
      url: collectionUrl,
      headers: {
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
      },
      body: Uint8List.fromList(utf8.encode(_propfindBody)),
      username: username,
      password: password,
    );
    _ensureOk(resp, 'PROPFIND $collectionUrl');
    final xml = utf8.decode(await resp.stream.toBytes());
    return _parseHrefs(xml);
  }

  Future<http.StreamedResponse> _send({
    required String method,
    required Uri url,
    Uint8List? body,
    Map<String, String> headers = const {},
    String? username,
    String? password,
  }) async {
    final req = http.Request(method, url);
    req.headers.addAll(headers);
    final auth = _basicAuth(username, password);
    if (auth != null) {
      req.headers['Authorization'] = auth;
    }
    if (body != null && body.isNotEmpty) {
      req.bodyBytes = body;
    }
    return httpClient.send(req);
  }

  static String? _basicAuth(String? username, String? password) {
    if (username == null || username.isEmpty) return null;
    final token = base64Encode(utf8.encode('$username:${password ?? ''}'));
    return 'Basic $token';
  }

  void _ensureOk(http.StreamedResponse resp, String op) {
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      resp.stream.drain<void>();
      throw WebDavException(resp.statusCode, op);
    }
  }

  /// Asks for resourcetype only — enough to distinguish files from collections
  /// and the cheapest PROPFIND most servers accept.
  static const String _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<propfind xmlns="DAV:">'
      '<prop><resourcetype/></prop>'
      '</propfind>';

  /// Extracts every `<...href>VALUE</...href>` (namespace-prefix tolerant),
  /// URL-decodes each, and drops collections (trailing `/`).
  static List<String> _parseHrefs(String xml) {
    final hrefs = <String>[];
    final re = RegExp(r'<\w*:?\w*href>([^<]+)</\w*:?\w*href>');
    for (final m in re.allMatches(xml)) {
      final raw = m.group(1)!.trim();
      final decoded = Uri.decodeFull(raw);
      if (decoded.endsWith('/')) continue; // collection, not a file
      hrefs.add(decoded);
    }
    return hrefs;
  }
}