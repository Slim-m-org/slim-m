// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [downloadArtifact]: what it reuses and what it throws away between runs.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/desktop/self_update/update_download.dart';
import 'package:slimm_app/src/desktop/self_update/update_manifest.dart';

class _Client extends http.BaseClient {
  _Client(this.body);
  final Uint8List body;
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final range = request.headers['Range'];
    if (range == null) return http.StreamedResponse(Stream.value(body), 200);
    final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
    return http.StreamedResponse(Stream.value(body.sublist(from)), 206);
  }
}

UpdateArtifact _artifact(Uint8List bytes) {
  final hash = Sha256().toSync().hashSync(bytes).bytes;
  return UpdateArtifact(
    url: Uri.parse('https://example.invalid/slim-m-client-android.apk'),
    sha256: hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    size: bytes.length,
  );
}

void main() {
  late Directory staging;
  final v2 = Uint8List.fromList(List.generate(4096, (i) => i % 251));
  final v1 = Uint8List.fromList(List.generate(4096, (i) => (i * 7) % 253));

  setUp(() async {
    staging = await Directory.systemTemp.createTemp('slimm-download-');
  });
  tearDown(() => staging.delete(recursive: true));

  Future<File> fetch(UpdateArtifact artifact, http.Client client) =>
      downloadArtifact(
        artifact: artifact,
        stagingDir: staging,
        client: client,
        freeSpace: (_) async => 1 << 40,
      );

  test(
    'a verified apk already staged is returned without a download',
    () async {
      final artifact = _artifact(v2);
      final client = _Client(v2);
      await fetch(artifact, client);
      client.requests.clear();

      final again = await fetch(artifact, client);

      expect(client.requests, isEmpty);
      expect(await again.readAsBytes(), v2);
    },
  );

  test('a staged file of another build is replaced, not trusted', () async {
    await File('${staging.path}/slim-m-client-android.apk').writeAsBytes(v1);
    final client = _Client(v2);

    final file = await fetch(_artifact(v2), client);

    expect(client.requests, hasLength(1));
    expect(await file.readAsBytes(), v2);
  });

  test('a partial from an older build is discarded, not resumed', () async {
    final old = _artifact(v1);
    await File(
      '${staging.path}/${partFileName(old)}',
    ).writeAsBytes(v1.sublist(0, 1000));
    final client = _Client(v2);

    final file = await fetch(_artifact(v2), client);

    expect(client.requests.single.headers['Range'], isNull);
    expect(await file.readAsBytes(), v2);
    expect(
      staging.listSync().map((e) => e.path).where((n) => n.endsWith('.part')),
      isEmpty,
    );
  });

  test('a partial of this build still resumes', () async {
    final artifact = _artifact(v2);
    await File(
      '${staging.path}/${partFileName(artifact)}',
    ).writeAsBytes(v2.sublist(0, 1000));
    final client = _Client(v2);

    final file = await fetch(artifact, client);

    expect(client.requests.single.headers['Range'], 'bytes=1000-');
    expect(await file.readAsBytes(), v2);
  });
}
