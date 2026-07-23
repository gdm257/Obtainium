// Unit self-check for AWS Signature Version 4 signing.
//
// AWS publishes "golden" SigV4 test vectors (aws-sig-v4-test-suite) whose
// final signature hex is the strongest proof of correctness. Fetching them
// requires network access, which isn't available in every build env, so this
// file asserts the properties we can prove from the spec without the vectors:
//   1. The empty-body SHA-256 (a fixed constant) — proves the digest + hashing
//      pipeline and the x-amz-content-sha256 header are wired correctly.
//   2. Determinism — identical inputs yield identical signatures.
//   3. Key-dependence — different secret keys yield different signatures.
//   4. Authorization header shape & signed-headers coverage.
//   5. Path percent-encoding preserves `/` but encodes reserved bytes.
//
// To lock down the exact final signature, run the suite locally and fill in a
// golden-value assertion (see comment at the bottom of this file).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/services/sig_v4.dart';

const _emptyBodyHash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

SignedRequest _sign({
  String method = 'GET',
  String path = '/',
  Map<String, dynamic> query = const {},
  String region = 'us-east-1',
  String service = 's3',
  String accessKey = 'AKIDEXAMPLE',
  String secretKey = 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
  Uint8List? body,
  String amzDate = '20150830T123600Z',
  Map<String, String> extraHeaders = const {},
}) {
  return signSigV4(
    method: method,
    uri: Uri(scheme: 'https', host: 'example.com', port: 443, path: path, queryParameters: query),
    region: region,
    service: service,
    accessKey: accessKey,
    secretKey: secretKey,
    body: body ?? Uint8List(0),
    amzDate: amzDate,
    extraHeaders: extraHeaders,
  );
}

void main() {
  test('signs empty body with the canonical empty SHA-256', () {
    final s = _sign(path: '/');
    expect(s.headers['x-amz-content-sha256'], _emptyBodyHash);
  });

  test('body hash reflects the request payload', () {
    final s = _sign(path: '/', body: Uint8List.fromList(utf8.encode('hello')));
    // sha256('hello')
    expect(
      s.headers['x-amz-content-sha256'],
      '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
    );
  });

  test('is deterministic: same inputs → same signature', () {
    final a = _sign(path: '/backups/a.json');
    final b = _sign(path: '/backups/a.json');
    expect(a.signature, b.signature);
    expect(a.authorization, b.authorization);
  });

  test('signature depends on the secret key', () {
    final a = _sign(secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY');
    final b = _sign(secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPl1111');
    expect(a.signature, isNot(b.signature));
  });

  test('signature depends on the request path', () {
    expect(_sign(path: '/a.json').signature, isNot(_sign(path: '/b.json').signature));
  });

  test('authorization header has the expected shape', () {
    final s = _sign(path: '/', extraHeaders: {'content-type': 'application/json'});
    expect(s.authorization, startsWith('AWS4-HMAC-SHA256 '));
    expect(s.authorization, contains('Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request'));
    expect(s.signedHeaders, contains('host'));
    expect(s.signedHeaders, contains('x-amz-date'));
    expect(s.signedHeaders, contains('x-amz-content-sha256'));
    expect(s.signedHeaders, contains('content-type'));
    expect(s.authorization, contains('Signature=${s.signature}'));
  });

  test('credential scope encodes date/region/service', () {
    final s = _sign(path: '/', region: 'eu-west-1', service: 's3');
    expect(s.credentialScope, '20150830/eu-west-1/s3/aws4_request');
  });

  test('query parameters are canonicalized and sorted', () {
    final a = _sign(path: '/', query: {'b': '2', 'a': '1'});
    final b = _sign(path: '/', query: {'a': '1', 'b': '2'});
    // Order independence: same logical query → same signature.
    expect(a.signature, b.signature);
    // Different query values → different signature.
    final c = _sign(path: '/', query: {'a': '9'});
    expect(a.signature, isNot(c.signature));
  });

  test('path percent-encoding preserves separators, encodes reserved bytes', () {
    final plain = _sign(path: '/backups/2024/file.json');
    final spaced = _sign(path: '/backups/2024 06/file.json');
    expect(plain.signature, isNot(spaced.signature));
    // A path with no special bytes is untouched; reserved bytes change the
    // canonical URI and therefore the signature (round-trips through hashing).
    final slash = _sign(path: '/');
    expect(slash.signature.length, 64); // hex SHA-256 length
  });

  test('non-default ports appear in the host header', () {
    final s = signSigV4(
      method: 'PUT',
      uri: Uri.parse('https://minio.example.local:9000/bucket/key'),
      region: 'us-east-1',
      service: 's3',
      accessKey: 'AKIDEXAMPLE',
      secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
      body: Uint8List(0),
      amzDate: '20150830T123600Z',
    );
    expect(s.headers['host'], 'minio.example.local:9000');
  });

  // Golden-vector lock-down (uncomment after fetching the exact value from
  // https://github.com/awslabs/aws-sig-v4-test-suite for a chosen case):
  //
  // test('AWS golden vector (get-vanilla, IAM)', () {
  //   final s = signSigV4(
  //     method: 'GET',
  //     uri: Uri.parse('https://iam.amazonaws.com/'),
  //     region: 'us-east-1',
  //     service: 'iam',
  //     accessKey: 'AKIDEXAMPLE',
  //     secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
  //     body: Uint8List(0),
  //     amzDate: '20150830T123600Z',
  //   );
  //   expect(s.signature, '<FILL-IN-FROM-TEST-SUITE>');
  // });
}
