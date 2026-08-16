import 'dart:convert';

import 'package:crypto/crypto.dart';

/// AWS Signature Version 4 helpers — pure functions, no I/O.
///
/// Only what the cloud-backup feature needs (PutObject / GetObject /
/// ListObjects on S3): canonical request, string-to-sign, signature, and the
/// Authorization header assembly. Tested against AWS's published reference
/// vectors (see test/cloud_backup/s3_signer_test.dart and the `selfCheck`
/// below) so the signing math is anchored to an external source of truth, not
/// recomputed the same way the code computes it.
///
/// ponytail: zero new deps — `crypto` gives the HMAC-SHA256 SigV4 needs.

/// SHA-256 hex of the empty string (the "unsigned payload" sentinel S3 accepts
/// when streaming or when the body hash is computed elsewhere).
const String emptyStringSha256Hex =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/// Lowercase hex SHA-256 of [bytes].
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

String _trimAll(String s) => s.trim().replaceAll(RegExp(r' +'), ' ');

/// Builds the canonical request string per AWS SigV4 step 1. [payloadHash] is
/// the hex SHA-256 of the request body (or [emptyStringSha256Hex]).
String canonicalRequest({
  required String method,
  required Uri uri,
  required Map<String, String> headers,
  required String payloadHash,
}) {
  // Canonical URI: absolute path, URI-encoded except the slashes that separate
  // segments; an empty path becomes "/".
  final String rawPath = uri.path.isEmpty ? '/' : uri.path;
  final String canonicalUri = _encodePath(rawPath);

  // Canonical query string: URI-encoded k=v pairs sorted by key name.
  final List<String> pairs =
      uri.queryParametersAll.entries
          .map((e) {
            return e.value
                .map((v) => '${_encode(e.key)}=${_encode(v)}')
                .toList();
          })
          .expand((p) => p)
          .toList()
        ..sort();
  final String canonicalQueryString = pairs.join('&');

  // Canonical + signed headers: lowercase names, trimmed values, sorted.
  final List<MapEntry<String, String>> lower = headers.entries
      .map((e) => MapEntry(e.key.toLowerCase(), _trimAll(e.value)))
      .toList();
  lower.sort((a, b) => a.key.compareTo(b.key));
  final String canonicalHeaders = lower
      .map((e) => '${e.key}:${e.value}\n')
      .join();
  final String signedHeaders = lower.map((e) => e.key).join(';');

  return [
    method.toUpperCase(),
    canonicalUri,
    canonicalQueryString,
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join('\n');
}

String _encodePath(String path) {
  // Encode each segment but keep "/" literal — S3 objects may have encoded
  // slashes inside keys, but the path separators themselves stay "/".
  final segments = path.split('/');
  return segments.map(_encode).join('/');
}

String _encode(String s) {
  // Unreserved per RFC 3986 stay literal; everything else is percent-encoded.
  final RegExp unreserved = RegExp(r'[A-Za-z0-9\-._~]');
  final StringBuffer out = StringBuffer();
  for (final int c in utf8.encode(s)) {
    final ch = String.fromCharCode(c);
    if (unreserved.hasMatch(ch)) {
      out.write(ch);
    } else {
      out.write('%${c.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// The credential scope string: `<dateStamp>/<region>/<service>/aws4_request`.
String scope({
  required String dateStamp,
  required String region,
  required String service,
}) {
  return '$dateStamp/$region/$service/aws4_request';
}

/// Builds the string-to-sign per AWS SigV4 step 2.
String stringToSign({
  required String amzDate,
  required String dateStamp,
  required String region,
  required String service,
  required String canonicalRequest,
}) {
  final String hashed = sha256Hex(utf8.encode(canonicalRequest));
  return [
    'AWS4-HMAC-SHA256',
    amzDate,
    scope(dateStamp: dateStamp, region: region, service: service),
    hashed,
  ].join('\n');
}

/// Derives the signing key and returns the lowercase-hex signature of
/// [stringToSign] per AWS SigV4 steps 3–4.
String signature({
  required String secretKey,
  required String dateStamp,
  required String region,
  required String service,
  required String stringToSign,
}) {
  final List<int> kDate = _hmac(
    utf8.encode('AWS4$secretKey'),
    utf8.encode(dateStamp),
  );
  final List<int> kRegion = _hmac(kDate, utf8.encode(region));
  final List<int> kService = _hmac(kRegion, utf8.encode(service));
  final List<int> kSigning = _hmac(kService, utf8.encode('aws4_request'));
  return _hmac(
    kSigning,
    utf8.encode(stringToSign),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

List<int> _hmac(List<int> key, List<int> data) =>
    Hmac(sha256, key).convert(data).bytes;

/// Assembles the final `Authorization` header value.
String authorizationHeader({
  required String accessKey,
  required String scope,
  required String signedHeaders,
  required String signatureHex,
}) {
  return 'AWS4-HMAC-SHA256 '
      'Credential=$accessKey/$scope, '
      'SignedHeaders=$signedHeaders, '
      'Signature=$signatureHex';
}

/// Minimal self-check against AWS's "get-vanilla" reference vector. Returns
/// true when our signature matches the published value. Call from a debug path
/// or from a test; never asserts on a real S3 call without it.
bool selfCheck() {
  const cr =
      'GET\n'
      '/\n'
      '\n'
      'host:example.amazonaws.com\n'
      'x-amz-date:20150830T123600Z\n'
      '\n'
      'host;x-amz-date\n'
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
  final sts = stringToSign(
    amzDate: '20150830T123600Z',
    dateStamp: '20150830',
    region: 'us-east-1',
    service: 'service',
    canonicalRequest: cr,
  );
  final sig = signature(
    secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
    dateStamp: '20150830',
    region: 'us-east-1',
    service: 'service',
    stringToSign: sts,
  );
  return sig ==
      '5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31';
}
