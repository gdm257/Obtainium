import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Result of an AWS Signature Version 4 signing pass. [headers] holds every
/// header that participates in the signature (host, x-amz-date,
/// x-amz-content-sha256, plus any extra) and must be sent verbatim on the HTTP
/// request; [authorization] is the full `Authorization` header value.
typedef SignedRequest = ({
  String authorization,
  String signature,
  String signedHeaders,
  String credentialScope,
  Map<String, String> headers,
});

/// Build an AWS Signature Version 4 signed request for a single HTTP call.
///
/// Pure function: same inputs always yield the same [signature], so it can be
/// validated against the official AWS SigV4 test vectors with no network.
///
/// [uri] must be fully resolved (scheme, host, port, path, query). The body is
/// always fully hashed (no `UNSIGNED-PAYLOAD`). [extraHeaders] are additional
/// headers to sign and send (e.g. `content-type`); names are case-insensitive.
SignedRequest signSigV4({
  required String method,
  required Uri uri,
  required String region,
  required String service,
  required String accessKey,
  required String secretKey,
  required Uint8List body,
  required String amzDate,
  Map<String, String> extraHeaders = const {},
}) {
  final payloadHash = sha256.convert(body).toString();
  final hostHeader = _hostHeader(uri);

  final headers = <String, String>{
    'host': hostHeader,
    'x-amz-date': amzDate,
    'x-amz-content-sha256': payloadHash,
    for (final e in extraHeaders.entries) e.key.toLowerCase().trim(): e.value,
  };

  final sortedKeys = headers.keys.toList()..sort();
  final canonicalHeaders =
      sortedKeys.map((k) => '$k:${_collapse(headers[k]!)}\n').join();
  final signedHeaders = sortedKeys.join(';');

  final canonicalRequest = [
    method.toUpperCase(),
    _canonicalUri(uri.path),
    _canonicalQuery(uri.queryParametersAll),
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join('\n');

  final dateStamp = amzDate.substring(0, 8);
  final credentialScope = '$dateStamp/$region/$service/aws4_request';

  final stringToSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    credentialScope,
    sha256.convert(utf8.encode(canonicalRequest)).toString(),
  ].join('\n');

  // Derived signing key: kSecret -> kDate -> kRegion -> kService -> kSigning
  final kDate = _hmac(utf8.encode('AWS4$secretKey'), utf8.encode(dateStamp));
  final kRegion = _hmac(kDate, utf8.encode(region));
  final kService = _hmac(kRegion, utf8.encode(service));
  final kSigning = _hmac(kService, utf8.encode('aws4_request'));

  final signature = _hex(_hmac(kSigning, utf8.encode(stringToSign)));

  final authorization =
      'AWS4-HMAC-SHA256 Credential=$accessKey/$credentialScope, '
      'SignedHeaders=$signedHeaders, Signature=$signature';

  return (
    authorization: authorization,
    signature: signature,
    signedHeaders: signedHeaders,
    credentialScope: credentialScope,
    headers: headers,
  );
}

String _hostHeader(Uri uri) {
  final isDefaultPort = (uri.scheme == 'http' && uri.port == 80) ||
      (uri.scheme == 'https' && uri.port == 443) ||
      !uri.hasPort;
  return isDefaultPort ? uri.host : '${uri.host}:${uri.port}';
}

/// Percent-encode each path segment, preserving `/` separators (AWS S3 rule).
String _canonicalUri(String path) {
  final p = path.isEmpty ? '/' : path;
  final encoded = p
      .split('/')
      .map((seg) => seg.isEmpty ? '' : Uri.encodeComponent(seg))
      .join('/');
  return encoded.startsWith('/') ? encoded : '/$encoded';
}

/// Sort by encoded name, `name=value` joined by `&`.
String _canonicalQuery(Map<String, List<String>> params) {
  if (params.isEmpty) return '';
  final pairs = <MapEntry<String, String>>[];
  params.forEach((name, values) {
    final encName = Uri.encodeQueryComponent(name);
    for (final v in values) {
      pairs.add(MapEntry(encName, Uri.encodeQueryComponent(v)));
    }
  });
  pairs.sort((a, b) => a.key.compareTo(b.key));
  return pairs.map((e) => '${e.key}=${e.value}').join('&');
}

/// Trim and collapse internal whitespace runs to a single space.
String _collapse(String value) => value.trim().replaceAll(RegExp(r'\s+'), ' ');

List<int> _hmac(List<int> key, List<int> data) =>
    Hmac(sha256, key).convert(data).bytes;

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
