import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/services/cloud_backup/webdav_client.dart';

class _RecordingClient extends http.BaseClient {
  http.Request? lastRequest;
  Uint8List nextBody = Uint8List(0);
  int nextStatus = 200;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request as http.Request;
    return http.StreamedResponse(
      http.ByteStream.fromBytes(nextBody),
      nextStatus,
      request: request,
    );
  }
}

void main() {
  const username = 'user';
  const password = 'pass';
  // base64('user:pass') — a known literal, not recomputed by the client's code.
  const expectedBasic = 'Basic dXNlcjpwYXNz';

  late _RecordingClient http_;
  late WebDavClient webdav;

  setUp(() {
    http_ = _RecordingClient();
    webdav = WebDavClient(http_);
  });

  group('putFile', () {
    test('PUTs the body to the URL with HTTP Basic auth', () async {
      final body = Uint8List.fromList(utf8.encode('hello dav'));
      await webdav.putFile(
        url: Uri.parse('https://dav.example.com/backups/a.json'),
        body: body,
        username: username,
        password: password,
      );
      final req = http_.lastRequest!;
      expect(req.method, 'PUT');
      expect(req.url.toString(), 'https://dav.example.com/backups/a.json');
      expect(req.bodyBytes, body);
      expect(req.headers['Authorization'], expectedBasic);
    });

    test('omits Authorization when no credentials are given', () async {
      await webdav.putFile(
        url: Uri.parse('https://dav.example.com/backups/a.json'),
        body: Uint8List(0),
      );
      expect(http_.lastRequest!.headers.containsKey('Authorization'), isFalse);
    });

    test('throws on a non-2xx response', () async {
      http_.nextStatus = 409;
      expect(
        () => webdav.putFile(
          url: Uri.parse('https://dav.example.com/backups/a.json'),
          body: Uint8List(0),
          username: username,
          password: password,
        ),
        throwsA(isA<WebDavException>()),
      );
    });
  });

  group('getFile', () {
    test('GETs the URL and returns the body', () async {
      http_.nextBody = Uint8List.fromList(utf8.encode('{"apps":[]}'));
      final out = await webdav.getFile(
        url: Uri.parse('https://dav.example.com/backups/a.json'),
        username: username,
        password: password,
      );
      expect(http_.lastRequest!.method, 'GET');
      expect(utf8.decode(out), '{"apps":[]}');
    });

    test('throws on 404', () async {
      http_.nextStatus = 404;
      expect(
        () => webdav.getFile(
          url: Uri.parse('https://dav.example.com/missing'),
          username: username,
          password: password,
        ),
        throwsA(isA<WebDavException>()),
      );
    });
  });

  group('listFiles', () {
    test('issues PROPFIND with Depth:1 and parses hrefs, skipping collections', () async {
      http_.nextBody = Uint8List.fromList(utf8.encode(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<d:multistatus xmlns:d="DAV:">'
        '<d:response>'
        '<d:href>/backups/</d:href>'
        '<d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>'
        '<d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
        '</d:response>'
        '<d:response>'
        '<d:href>/backups/a.json</d:href>'
        '<d:propstat><d:prop><d:resourcetype/></d:prop>'
        '<d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
        '</d:response>'
        '<d:response>'
        '<d:href>/backups/b.json</d:href>'
        '<d:propstat><d:prop><d:resourcetype/></d:prop>'
        '<d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
        '</d:response>'
        '</d:multistatus>',
      ));
      final hrefs = await webdav.listFiles(
        collectionUrl: Uri.parse('https://dav.example.com/backups/'),
        username: username,
        password: password,
      );
      final req = http_.lastRequest!;
      expect(req.method, 'PROPFIND');
      expect(req.headers['Depth'], '1');
      expect(req.headers['Authorization'], expectedBasic);
      // The collection itself (trailing '/') is dropped.
      expect(hrefs, ['/backups/a.json', '/backups/b.json']);
    });
  });
}