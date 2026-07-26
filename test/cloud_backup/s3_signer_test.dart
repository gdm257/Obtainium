import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/services/cloud_backup/s3_signer.dart';

/// Vectors are the authoritative AWS SigV4 test suite (the community mirror of
/// AWS's own sig-v4-test-suite). These are an external source of truth — they
/// are NOT values recomputed the way our code computes them, so a bug in the
/// signer will produce a mismatch rather than a tautological pass.
/// Source: github.com/saibotsivad/aws-sig-v4-test-suite (AWS "get-vanilla"
/// family). Region us-east-1, service "service", host example.amazonaws.com,
/// access key AKIDEXAMPLE, secret wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY,
/// X-Amz-Date 20150830T123600Z (dateStamp 20150830).
const _secretKey = 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY';

class _Vector {
  final String name;
  final String method;
  final String url;
  final String expectedCanonicalRequest;
  final String expectedStringToSign;
  final String expectedSignature;

  const _Vector({
    required this.name,
    required this.method,
    required this.url,
    required this.expectedCanonicalRequest,
    required this.expectedStringToSign,
    required this.expectedSignature,
  });
}

const _vectors = <_Vector>[
  _Vector(
    name: 'get-vanilla (no query)',
    method: 'GET',
    url: 'https://example.amazonaws.com/',
    expectedCanonicalRequest:
        'GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    expectedStringToSign:
        'AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\nbb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63',
    expectedSignature:
        '5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31',
  ),
  _Vector(
    name: 'get-vanilla-empty-query-key (single param)',
    method: 'GET',
    url: 'https://example.amazonaws.com/?Param1=value1',
    expectedCanonicalRequest:
        'GET\n/\nParam1=value1\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    expectedStringToSign:
        'AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n1e24db194ed7d0eec2de28d7369675a243488e08526e8c1c73571282f7c517ab',
    expectedSignature:
        'a67d582fa61cc504c4bae71f336f98b97f1ea3c7a6bfe1b6e45aec72011b9aeb',
  ),
  _Vector(
    // Reordered query params (Param2 before Param1 in the request) must be
    // sorted by key in the canonical query string — this vector catches a
    // sort bug.
    name: 'get-vanilla-query-order-key-case (sorted params)',
    method: 'GET',
    url: 'https://example.amazonaws.com/?Param2=value2&Param1=value1',
    expectedCanonicalRequest:
        'GET\n/\nParam1=value1&Param2=value2\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    expectedStringToSign:
        'AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n816cd5b414d056048ba4f7c5386d6e0533120fb1fcfa93762cf0fc39e2cf19e0',
    expectedSignature:
        'b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500',
  ),
];

void main() {
  const headers = {
    'Host': 'example.amazonaws.com',
    'X-Amz-Date': '20150830T123600Z',
  };

  for (final v in _vectors) {
    group('AWS vector: ${v.name}', () {
      test('canonical request', () {
        expect(
          canonicalRequest(
            method: v.method,
            uri: Uri.parse(v.url),
            headers: headers,
            payloadHash: emptyStringSha256Hex,
          ),
          v.expectedCanonicalRequest,
        );
      });

      test('string-to-sign', () {
        final cr = canonicalRequest(
          method: v.method,
          uri: Uri.parse(v.url),
          headers: headers,
          payloadHash: emptyStringSha256Hex,
        );
        expect(
          stringToSign(
            amzDate: '20150830T123600Z',
            dateStamp: '20150830',
            region: 'us-east-1',
            service: 'service',
            canonicalRequest: cr,
          ),
          v.expectedStringToSign,
        );
      });

      test('signature', () {
        final cr = canonicalRequest(
          method: v.method,
          uri: Uri.parse(v.url),
          headers: headers,
          payloadHash: emptyStringSha256Hex,
        );
        final sts = stringToSign(
          amzDate: '20150830T123600Z',
          dateStamp: '20150830',
          region: 'us-east-1',
          service: 'service',
          canonicalRequest: cr,
        );
        expect(
          signature(
            secretKey: _secretKey,
            dateStamp: '20150830',
            region: 'us-east-1',
            service: 'service',
            stringToSign: sts,
          ),
          v.expectedSignature,
        );
      });
    });
  }

  test('Authorization header builds AWS4 form with all fields', () {
    final auth = authorizationHeader(
      accessKey: 'AKIDEXAMPLE',
      scope: scope(dateStamp: '20150830', region: 'us-east-1', service: 'service'),
      signedHeaders: 'host;x-amz-date',
      signatureHex: 'deadbeef',
    );
    expect(
      auth,
      'AWS4-HMAC-SHA256 '
      'Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, '
      'SignedHeaders=host;x-amz-date, '
      'Signature=deadbeef',
    );
  });

  test('selfCheck passes against the get-vanilla vector', () {
    expect(selfCheck(), isTrue);
  });
}
