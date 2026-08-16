import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/services/cloud_backup/cloud_backup_service.dart';
import 'package:obtainium/services/cloud_backup/s3_client.dart';
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

S3Client _s3(_RecordingClient c) =>
    S3Client(c, now: () => DateTime.utc(2015, 8, 30, 12, 36, 0));
WebDavClient _webdav(_RecordingClient c) => WebDavClient(c);

const s3Config = CloudBackupConfig(
  active: CloudBackend.s3,
  s3Endpoint: 'https://s3.us-east-1.amazonaws.com',
  s3Bucket: 'my-bucket',
  s3Region: 'us-east-1',
  s3Prefix: 'backups/',
  s3AccessKey: 'AKIDEXAMPLE',
  s3SecretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
);

const webdavConfig = CloudBackupConfig(
  active: CloudBackend.webdav,
  webdavBaseUrl: 'https://dav.example.com/dav/',
  webdavPrefix: 'backups/',
  webdavUsername: 'user',
  webdavPassword: 'pass',
);

void main() {
  group('upload', () {
    test('S3 active: PUTs to <endpoint>/<bucket>/<prefix+filename>', () async {
      final http_ = _RecordingClient();
      final svc = CloudBackupService(_s3(http_), _webdav(_RecordingClient()));
      await svc.upload(
        s3Config,
        filename: 'obtainx-export-2026.json',
        bytes: Uint8List.fromList(utf8.encode('x')),
      );
      final req = http_.lastRequest!;
      expect(req.method, 'PUT');
      expect(
        req.url.toString(),
        'https://s3.us-east-1.amazonaws.com/my-bucket/backups/obtainx-export-2026.json',
      );
    });

    test('WebDAV active: PUTs to <baseUrl>/<prefix><filename>', () async {
      final http_ = _RecordingClient();
      final svc = CloudBackupService(_s3(_RecordingClient()), _webdav(http_));
      await svc.upload(
        webdavConfig,
        filename: 'obtainx-export-2026.json',
        bytes: Uint8List.fromList(utf8.encode('x')),
      );
      final req = http_.lastRequest!;
      expect(req.method, 'PUT');
      expect(
        req.url.toString(),
        'https://dav.example.com/dav/backups/obtainx-export-2026.json',
      );
      expect(req.headers['Authorization'], 'Basic dXNlcjpwYXNz');
    });

    test('throws when no backend is active', () async {
      final svc = CloudBackupService(
        _s3(_RecordingClient()),
        _webdav(_RecordingClient()),
      );
      expect(
        () => svc.upload(
          const CloudBackupConfig(active: CloudBackend.none),
          filename: 'x.json',
          bytes: Uint8List(0),
        ),
        throwsA(isA<CloudBackupConfigException>()),
      );
    });
  });

  group('list', () {
    test('S3: returns entries with basename display + full-key ref', () async {
      final http_ = _RecordingClient();
      http_.nextBody = Uint8List.fromList(
        utf8.encode(
          '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
          '<Contents><Key>backups/a.json</Key></Contents>'
          '<Contents><Key>backups/b.json</Key></Contents>'
          '</ListBucketResult>',
        ),
      );
      final svc = CloudBackupService(_s3(http_), _webdav(_RecordingClient()));
      final entries = await svc.list(s3Config);
      expect(entries.map((e) => e.name), ['a.json', 'b.json']);
      expect(entries.first.ref, 'backups/a.json');
    });

    test('WebDAV: returns entries with basename display + href ref', () async {
      final http_ = _RecordingClient();
      http_.nextBody = Uint8List.fromList(
        utf8.encode(
          '<d:multistatus xmlns:d="DAV:">'
          '<d:response><d:href>/dav/backups/</d:href>'
          '<d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>'
          '</d:response>'
          '<d:response><d:href>/dav/backups/a.json</d:href>'
          '<d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>'
          '</d:response>'
          '</d:multistatus>',
        ),
      );
      final svc = CloudBackupService(_s3(_RecordingClient()), _webdav(http_));
      final entries = await svc.list(webdavConfig);
      expect(entries.map((e) => e.name), ['a.json']);
      expect(entries.first.ref, '/dav/backups/a.json');
    });
  });

  group('download', () {
    test('S3: GETs objectKey built from prefix + entry name', () async {
      final http_ = _RecordingClient();
      http_.nextBody = Uint8List.fromList(utf8.encode('payload'));
      final svc = CloudBackupService(_s3(http_), _webdav(_RecordingClient()));
      final out = await svc.download(
        s3Config,
        const CloudBackupEntry(name: 'a.json', ref: 'backups/a.json'),
      );
      final req = http_.lastRequest!;
      expect(req.method, 'GET');
      expect(
        req.url.toString(),
        'https://s3.us-east-1.amazonaws.com/my-bucket/backups/a.json',
      );
      expect(utf8.decode(out), 'payload');
    });

    test('WebDAV: GETs the entry href as an absolute URL', () async {
      final http_ = _RecordingClient();
      http_.nextBody = Uint8List.fromList(utf8.encode('payload'));
      final svc = CloudBackupService(_s3(_RecordingClient()), _webdav(http_));
      final out = await svc.download(
        webdavConfig,
        const CloudBackupEntry(name: 'a.json', ref: '/dav/backups/a.json'),
      );
      final req = http_.lastRequest!;
      expect(req.method, 'GET');
      expect(req.url.toString(), 'https://dav.example.com/dav/backups/a.json');
      expect(utf8.decode(out), 'payload');
    });
  });
}
