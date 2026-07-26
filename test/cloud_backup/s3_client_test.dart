import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/services/cloud_backup/s3_client.dart';
import 'package:obtainium/services/cloud_backup/s3_signer.dart';

/// Captures the request S3Client sends and replays a canned response.
class _RecordingClient extends http.BaseClient {
  http.Request? lastRequest;
  Uint8List nextBody = Uint8List(0);
  int nextStatus = 200;
  Map<String, String> nextHeaders = const {};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request as http.Request;
    return http.StreamedResponse(
      http.ByteStream.fromBytes(nextBody),
      nextStatus,
      request: request,
      headers: nextHeaders,
    );
  }
}

void main() {
  const endpoint = 'https://s3.us-east-1.amazonaws.com';
  const bucket = 'my-bucket';
  const region = 'us-east-1';
  const accessKey = 'AKIDEXAMPLE';
  const secretKey = 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY';

  late _RecordingClient http_;
  late S3Client s3;

  setUp(() {
    http_ = _RecordingClient();
    s3 = S3Client(http_, now: () => DateTime.utc(2015, 8, 30, 12, 36, 0));
  });

  group('putObject', () {
    test('issues a PUT to the path-style object URL with a signed AWS4 header', () async {
      final body = Uint8List.fromList(utf8.encode('hello cloud'));
      await s3.putObject(
        endpoint: Uri.parse(endpoint),
        bucket: bucket,
        region: region,
        objectKey: 'backups/obtainx-export-2026.json',
        body: body,
        accessKey: accessKey,
        secretKey: secretKey,
      );

      final req = http_.lastRequest!;
      expect(req.method, 'PUT');
      expect(req.url.toString(), '$endpoint/$bucket/backups/obtainx-export-2026.json');
      expect(req.bodyBytes, body);

      final headers = req.headers;
      expect(headers['Host'], 's3.us-east-1.amazonaws.com');
      expect(headers['x-amz-date'], '20150830T123600Z');
      expect(headers['x-amz-content-sha256'], sha256Hex(body));
      final auth = headers['Authorization']!;
      expect(auth.startsWith('AWS4-HMAC-SHA256 '), isTrue);
      expect(auth, contains('Credential=$accessKey/20150830/$region/s3/aws4_request'));
      expect(auth, contains('SignedHeaders=host;x-amz-content-sha256;x-amz-date'));
      expect(auth, contains('Signature='));
    });

    test('throws on a non-2xx response', () async {
      http_.nextStatus = 403;
      http_.nextBody = Uint8List.fromList(utf8.encode('Forbidden'));
      expect(
        () => s3.putObject(
          endpoint: Uri.parse(endpoint),
          bucket: bucket,
          region: region,
          objectKey: 'k',
          body: Uint8List(0),
          accessKey: accessKey,
          secretKey: secretKey,
        ),
        throwsA(isA<S3Exception>()),
      );
    });
  });

  group('getObject', () {
    test('GETs the object URL and returns the body bytes', () async {
      http_.nextBody = Uint8List.fromList(utf8.encode('{"apps":[]}'));
      final out = await s3.getObject(
        endpoint: Uri.parse(endpoint),
        bucket: bucket,
        region: region,
        objectKey: 'backups/x.json',
        accessKey: accessKey,
        secretKey: secretKey,
      );
      final req = http_.lastRequest!;
      expect(req.method, 'GET');
      expect(req.url.toString(), '$endpoint/$bucket/backups/x.json');
      expect(utf8.decode(out), '{"apps":[]}');
    });

    test('throws on 404', () async {
      http_.nextStatus = 404;
      expect(
        () => s3.getObject(
          endpoint: Uri.parse(endpoint),
          bucket: bucket,
          region: region,
          objectKey: 'missing',
          accessKey: accessKey,
          secretKey: secretKey,
        ),
        throwsA(isA<S3Exception>()),
      );
    });
  });

  group('listObjects', () {
    test('GETs ?list-type=2 and parses object keys from XML', () async {
      http_.nextBody = Uint8List.fromList(utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
        '<Contents><Key>backups/a.json</Key></Contents>'
        '<Contents><Key>backups/b.json</Key></Contents>'
        '<CommonPrefixes><Prefix>logs/</Prefix></CommonPrefixes>'
        '</ListBucketResult>',
      ));
      final keys = await s3.listObjects(
        endpoint: Uri.parse(endpoint),
        bucket: bucket,
        region: region,
        prefix: 'backups/',
        accessKey: accessKey,
        secretKey: secretKey,
      );
      final req = http_.lastRequest!;
      expect(req.method, 'GET');
      expect(req.url.queryParameters['list-type'], '2');
      expect(req.url.queryParameters['prefix'], 'backups/');
      expect(keys, ['backups/a.json', 'backups/b.json']);
    });
  });
}