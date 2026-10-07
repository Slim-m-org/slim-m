// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/desktop/self_update/self_update.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_failure.dart';
import 'package:slimm_app/src/desktop/self_update/update_download.dart';
import 'package:slimm_app/src/desktop/self_update/update_keys.dart';
import 'package:slimm_app/src/desktop/self_update/update_manifest.dart';

const _base =
    'https://github.com/Slim-m-org/slim-m/releases/download/client-v0.90.0';
const _releases =
    'https://api.github.com/repos/Slim-m-org/slim-m/releases?per_page=30';

typedef _Handler = FutureOr<http.StreamedResponse> Function(http.BaseRequest r);

class _FakeClient extends http.BaseClient {
  _FakeClient(this.handler);
  final _Handler handler;
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return handler(request);
  }
}

http.StreamedResponse _ok(List<int> body, {int status = 200}) =>
    http.StreamedResponse(Stream.value(body), status);

String _sha(List<int> bytes) => sha256Hex(bytes);

String sha256Hex(List<int> bytes) {
  final hash = Sha256().toSync().hashSync(bytes);
  return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class _Release {
  _Release({
    required this.key,
    this.version = '0.90.0',
    this.schema = 1,
    Uint8List? payload,
    this.declaredSize,
  }) : payload =
           payload ?? Uint8List.fromList(List.generate(4096, (i) => i % 251));

  final SimpleKeyPair key;
  final String version;
  final int schema;
  final Uint8List payload;
  final int? declaredSize;

  Uint8List manifest() => Uint8List.fromList(
    utf8.encode(
      '${const JsonEncoder.withIndent('  ').convert({
        'schema': schema,
        'version': version,
        'tag': 'client-v$version',
        'artifacts': {
          'linux-x64': {'url': '$_base/slim-m-client-$version-linux-amd64.tar.gz', 'sha256': _sha(payload), 'size': declaredSize ?? payload.length},
        },
      })}\n',
    ),
  );

  Future<String> signature(Uint8List bytes, [SimpleKeyPair? other]) async {
    final sig = await Ed25519().sign(bytes, keyPair: other ?? key);
    return base64.encode(sig.bytes);
  }
}

Future<String> _pub(SimpleKeyPair pair) async =>
    base64.encode((await pair.extractPublicKey()).bytes);

Future<_FakeClient> _server(
  _Release release, {
  Uint8List? manifestOverride,
  String? sigOverride,
  _Handler? artifact,
}) async {
  final manifest = release.manifest();
  final sig = sigOverride ?? await release.signature(manifest);
  return _FakeClient((r) async {
    final url = r.url.toString();
    if (url == _releases) {
      return _ok(
        utf8.encode(
          jsonEncode([
            {
              'tag_name': 'client-v0.90.0',
              'draft': false,
              'prerelease': false,
              'assets': [
                {'name': 'manifest.json'},
                {'name': 'manifest.json.sig'},
              ],
            },
            {'tag_name': 'v9.9.9', 'draft': false, 'prerelease': false},
          ]),
        ),
      );
    }
    if (url == '$_base/manifest.json') {
      return _ok(manifestOverride ?? manifest);
    }
    if (url == '$_base/manifest.json.sig') return _ok(utf8.encode(sig));
    if (artifact != null) return artifact(r);
    return _ok(release.payload);
  });
}

void main() {
  late Directory staging;
  late SimpleKeyPair key;
  late String pub;

  setUp(() async {
    staging = await Directory.systemTemp.createTemp('slimm-self-update-');
    key = await Ed25519().newKeyPair();
    pub = await _pub(key);
  });
  tearDown(() => staging.delete(recursive: true));

  Future<VerifiedUpdate?> run(
    http.Client client, {
    List<String>? keys,
    String current = '0.89.0',
    String platform = 'linux-x64',
    FreeSpace? freeSpace,
  }) => fetchVerifiedUpdateWith(
    currentVersion: current,
    platformKey: platform,
    stagingDir: staging,
    client: client,
    trustedKeys: keys ?? [pub],
    freeSpace: freeSpace ?? (_) async => 1 << 40,
  );

  Future<SelfUpdateFailureKind> failureOf(Future<Object?> call) async {
    try {
      await call;
    } on SelfUpdateFailure catch (f) {
      return f.kind;
    }
    fail('expected a SelfUpdateFailure');
  }

  List<String> stagedNames() =>
      staging.listSync().map((e) => e.uri.pathSegments.last).toList()
        ..removeWhere((n) => n.isEmpty);

  test('valid path downloads, verifies and names the file', () async {
    final release = _Release(key: key);
    final update = await run(await _server(release));
    expect(update, isNotNull);
    expect(update!.version, '0.90.0');
    expect(await update.file.readAsBytes(), release.payload);
    expect(stagedNames(), ['slim-m-client-0.90.0-linux-amd64.tar.gz']);
  });

  test('a tampered manifest is rejected before any download', () async {
    final release = _Release(key: key);
    final tampered = Uint8List.fromList(
      utf8.encode(
        utf8.decode(release.manifest()).replaceAll('0.90.0', '0.99.0'),
      ),
    );
    final client = await _server(release, manifestOverride: tampered);
    expect(await failureOf(run(client)), SelfUpdateFailureKind.badSignature);
    expect(stagedNames(), isEmpty);
    expect(
      client.requests.where((r) => r.url.path.endsWith('.tar.gz')),
      isEmpty,
    );
  });

  test('a signature by the wrong key is rejected', () async {
    final release = _Release(key: key);
    final stranger = await Ed25519().newKeyPair();
    final sig = await release.signature(release.manifest(), stranger);
    final client = await _server(release, sigOverride: sig);
    expect(await failureOf(run(client)), SelfUpdateFailureKind.badSignature);
  });

  test('rotation: any key in the list may have signed', () async {
    final oldKey = await Ed25519().newKeyPair();
    final release = _Release(key: key);
    final keys = [await _pub(oldKey), pub];
    expect(await run(await _server(release), keys: keys), isNotNull);
    final onlyOld = [await _pub(oldKey)];
    expect(
      await failureOf(run(await _server(release), keys: onlyOld)),
      SelfUpdateFailureKind.badSignature,
    );
  });

  test('a newer release with no artifact for this platform says so', () async {
    final client = await _server(_Release(key: key));
    try {
      await run(client, platform: 'macos');
      fail('expected a SelfUpdateFailure');
    } on SelfUpdateFailure catch (f) {
      expect(f.kind, SelfUpdateFailureKind.noArtifactForPlatform);
      expect(f.releaseUrl, endsWith('/releases/tag/client-v0.90.0'));
      expect(f.message, contains('no download for this platform'));
    }
    expect(stagedNames(), isEmpty);
  });

  test(
    'an older or equal version offers nothing and downloads nothing',
    () async {
      for (final version in ['0.89.0', '0.88.0']) {
        final client = await _server(_Release(key: key, version: version));
        expect(await run(client), isNull);
        expect(
          client.requests.where((r) => r.url.path.endsWith('.tar.gz')),
          isEmpty,
        );
      }
    },
  );

  test('an arm64 host never receives the x64 entry', () async {
    final client = await _server(_Release(key: key));
    expect(
      await failureOf(run(client, platform: 'linux-arm64')),
      SelfUpdateFailureKind.noArtifactForPlatform,
    );
    expect(
      client.requests.where((r) => r.url.path.endsWith('.tar.gz')),
      isEmpty,
    );
    expect(stagedNames(), isEmpty);
  });

  test('a signed version that is not plain digits names nothing', () async {
    for (final version in [
      '9.9.9-/../../x',
      '9.9.9-rc1',
      '9.9.9+b',
      '1.2',
      '1.0.0-../x',
      '1.0.0+a/b',
      '1.0.0-rc.1',
    ]) {
      final client = await _server(_Release(key: key, version: version));
      expect(
        await failureOf(run(client)),
        SelfUpdateFailureKind.badManifest,
        reason: version,
      );
      expect(stagedNames(), isEmpty);
    }
  });

  test('a manifest schema this build does not know is refused', () async {
    final client = await _server(_Release(key: key, schema: 2));
    expect(
      await failureOf(run(client)),
      SelfUpdateFailureKind.unsupportedSchema,
    );
  });

  test('a swapped artifact fails the sha256 and stages nothing', () async {
    final release = _Release(key: key);
    final client = await _server(
      release,
      artifact: (_) =>
          _ok(Uint8List.fromList(List.filled(release.payload.length, 7))),
    );
    expect(
      await failureOf(run(client)),
      SelfUpdateFailureKind.checksumMismatch,
    );
    expect(stagedNames(), isEmpty);
  });

  test('a size mismatch is discarded', () async {
    final release = _Release(key: key, declaredSize: 4096);
    final client = await _server(
      release,
      artifact: (_) => _ok(release.payload.sublist(0, 4000)),
    );
    expect(await failureOf(run(client)), SelfUpdateFailureKind.sizeMismatch);
    expect(stagedNames(), isEmpty);
  });

  test('a server sending more than the size stops at the limit', () async {
    final release = _Release(key: key);
    final client = await _server(
      release,
      artifact: (_) => _ok(Uint8List(release.payload.length + 5000)),
    );
    expect(await failureOf(run(client)), SelfUpdateFailureKind.sizeMismatch);
    expect(stagedNames(), isEmpty);
  });

  test('an interrupted download resumes with a Range request', () async {
    final release = _Release(key: key);
    var calls = 0;
    final client = await _server(
      release,
      artifact: (r) {
        calls++;
        if (calls == 1) {
          final broken = Stream<List<int>>.multi((c) {
            c.add(release.payload.sublist(0, 1500));
            c.addError(const SocketException('reset'));
            c.close();
          });
          return http.StreamedResponse(broken, 200);
        }
        expect(r.headers['Range'], 'bytes=1500-');
        return _ok(release.payload.sublist(1500), status: 206);
      },
    );
    final update = await run(client);
    expect(calls, 2);
    expect(await update!.file.readAsBytes(), release.payload);
  });

  test('a server that ignores Range restarts the file', () async {
    final release = _Release(key: key);
    await File(
      '${staging.path}/slim-m-client-0.90.0-linux-amd64.tar.gz.part',
    ).writeAsBytes(release.payload.sublist(0, 100));
    final client = await _server(release);
    final update = await run(client);
    expect(await update!.file.readAsBytes(), release.payload);
  });

  test('insufficient free space stops before downloading', () async {
    final release = _Release(key: key);
    final client = await _server(release);
    final kind = await failureOf(
      run(client, freeSpace: (_) async => release.payload.length * 2 - 1),
    );
    expect(kind, SelfUpdateFailureKind.insufficientSpace);
    expect(
      client.requests.where((r) => r.url.path.endsWith('.tar.gz')),
      isEmpty,
    );
    expect(stagedNames(), isEmpty);
  });

  test('a real signed manifest verifies against the compiled-in key', () async {
    const dir = 'test/desktop/self_update/fixtures';
    final bytes = await File('$dir/manifest.json').readAsBytes();
    final sig = await File('$dir/manifest.json.sig').readAsString();
    expect(
      await manifestSignatureIsValid(
        manifestBytes: bytes,
        signatureBase64: sig,
        trustedKeys: trustedUpdateKeys,
      ),
      isTrue,
    );
    expect(parseManifest(bytes).artifacts.keys, contains('linux-x64'));
  });
}
