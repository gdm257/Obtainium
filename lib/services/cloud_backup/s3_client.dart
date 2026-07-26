import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:obtainium/services/cloud_backup/s3_signer.dart';

/// Thrown when S3 returns a non-2xx status. Carries the status + body excerpt so
/// the UI can surface a useful message without leaking the full response.
class S3Exception implements Exception {
  S3Exception(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => 'S3Exception($statusCode): $message';
}

/// Minimal S3 client over plain HTTP using hand-written SigV4 (see
/// [s3_signer]). Path-style URLs (`<endpoint>/<bucket>/<key>`) so any
/// S3-compatible endpoint (AWS, MinIO, R2, …) works with a configured base URL.
///
/// The HTTP client is injected — production passes a real [http.Client], tests
/// pass a recording fake. The clock is also injectable so signing is
/// deterministic under test.
class S3Client {
  S3Client(this.httpClient, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final http.Client httpClient;
  final DateTime Function() _now;

  /// Uploads [body] to `<endpoint>/<bucket>/<objectKey>`. Overwrites if the key
  /// already exists (callers use a timestamped key to keep versions distinct).
  Future<void> putObject({
    required Uri endpoint,
    required String bucket,
    required String region,
    required String objectKey,
    required Uint8List body,
    required String accessKey,
    required String secretKey,
  }) async {
    final resp = await _send(
      method: 'PUT',
      endpoint: endpoint,
      bucket: bucket,
      objectKey: objectKey,
      region: region,
      accessKey: accessKey,
      secretKey: secretKey,
      body: body,
    );
    _ensureOk(resp, 'PUT $objectKey');
  }

  /// Downloads `<endpoint>/<bucket>/<objectKey>` and returns its bytes.
  Future<Uint8List> getObject({
    required Uri endpoint,
    required String bucket,
    required String region,
    required String objectKey,
    required String accessKey,
    required String secretKey,
  }) async {
    final resp = await _send(
      method: 'GET',
      endpoint: endpoint,
      bucket: bucket,
      objectKey: objectKey,
      region: region,
      accessKey: accessKey,
      secretKey: secretKey,
    );
    _ensureOk(resp, 'GET $objectKey');
    final bytes = await resp.stream.toBytes();
    return Uint8List.fromList(bytes);
  }

  /// Lists object keys under [prefix] via ListObjectsV2 (`?list-type=2`).
  /// Returns keys in the order S3 reports them.
  Future<List<String>> listObjects({
    required Uri endpoint,
    required String bucket,
    required String region,
    required String prefix,
    required String accessKey,
    required String secretKey,
  }) async {
    final resp = await _send(
      method: 'GET',
      endpoint: endpoint,
      bucket: bucket,
      objectKey: '',
      region: region,
      accessKey: accessKey,
      secretKey: secretKey,
      query: {'list-type': '2', 'prefix': prefix},
    );
    _ensureOk(resp, 'LIST $prefix');
    final body = utf8.decode(await resp.stream.toBytes());
    return _parseListKeys(body);
  }

  Future<http.StreamedResponse> _send({
    required String method,
    required Uri endpoint,
    required String bucket,
    required String objectKey,
    required String region,
    required String accessKey,
    required String secretKey,
    Uint8List? body,
    Map<String, String> query = const {},
  }) async {
    final path = objectKey.isEmpty ? '/$bucket' : '/$bucket/$objectKey';
    final url = endpoint.replace(path: path, queryParameters: query.isEmpty ? null : query);

    final payloadHash =
        body == null ? emptyStringSha256Hex : sha256Hex(body);

    final now = _now().toUtc();
    final amzDate = _amzDate(now);
    final dateStamp = _dateStamp(now);

    final headers = <String, String>{
      'Host': url.host,
      'x-amz-date': amzDate,
      'x-amz-content-sha256': payloadHash,
    };

    final cr = canonicalRequest(
      method: method,
      uri: url,
      headers: headers,
      payloadHash: payloadHash,
    );
    final sts = stringToSign(
      amzDate: amzDate,
      dateStamp: dateStamp,
      region: region,
      service: 's3',
      canonicalRequest: cr,
    );
    final sig = signature(
      secretKey: secretKey,
      dateStamp: dateStamp,
      region: region,
      service: 's3',
      stringToSign: sts,
    );
    final auth = authorizationHeader(
      accessKey: accessKey,
      scope: scope(dateStamp: dateStamp, region: region, service: 's3'),
      signedHeaders: 'host;x-amz-content-sha256;x-amz-date',
      signatureHex: sig,
    );
    headers['Authorization'] = auth;

    final req = http.Request(method, url);
    req.headers.addAll(headers);
    if (body != null && body.isNotEmpty) {
      req.bodyBytes = body;
    }
    return httpClient.send(req);
  }

  void _ensureOk(http.StreamedResponse resp, String op) {
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      // Drain so the connection can be reused; ignore the bytes themselves.
      resp.stream.drain<void>();
      throw S3Exception(resp.statusCode, op);
    }
  }

  /// Extracts every `<Key>…</Key>` from a ListObjectsV2 response, ignoring
  /// `<Prefix>` entries (CommonPrefixes delimiters). No XML dependency: the S3
  /// list response is flat enough that a tag scan is sufficient and robust to
  /// namespace declarations.
  static List<String> _parseListKeys(String xml) {
    final keys = <String>[];
    int i = 0;
    const open = '<Key>';
    const close = '</Key>';
    while (true) {
      final s = xml.indexOf(open, i);
      if (s < 0) break;
      final e = xml.indexOf(close, s + open.length);
      if (e < 0) break;
      keys.add(xml.substring(s + open.length, e));
      i = e + close.length;
    }
    return keys;
  }
}

// ponytail: hand-built strings beat pulling in intl for two fixed date shapes.
String _two(int n) => n.toString().padLeft(2, '0');

/// SigV4 "AMZ date": yyyyMMddTHHmmssZ (UTC, literal trailing Z).
String _amzDate(DateTime utc) =>
    '${utc.year}${_two(utc.month)}${_two(utc.day)}T'
    '${_two(utc.hour)}${_two(utc.minute)}${_two(utc.second)}Z';

/// SigV4 "date stamp": yyyyMMdd (UTC).
String _dateStamp(DateTime utc) =>
    '${utc.year}${_two(utc.month)}${_two(utc.day)}';
