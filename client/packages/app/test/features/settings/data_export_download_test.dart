// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Saving and polling an export without the widget: a cancel, a dispose, a
/// double press, a target that is too small, and a poll that fails once.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/downloads/download_target.dart';
import 'package:slimm_app/src/downloads/downloads_controller.dart';
import 'package:slimm_app/src/features/settings/providers/data_export_download.dart';
import 'package:slimm_app/src/features/settings/providers/data_exports.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

const _job = api.DataExport(
  id: 'e1',
  kind: api.ExportKind.member,
  status: api.ExportStatus.ready,
  processed: 1,
  total: 1,
  createdAt: 1767225600000,
  sizeBytes: 4,
);

class _Target implements DownloadTarget {
  _Target({this.limit});

  final int? limit;
  final bytes = <int>[];
  bool finished = false;
  int discards = 0;

  @override
  int? get maxBytes => limit;

  @override
  Future<void> write(List<int> chunk) async => bytes.addAll(chunk);

  @override
  Future<bool> finish() async => finished = true;

  @override
  Future<void> discard() async => discards++;
}

class _Rig {
  _Rig(this.container, this.opened);

  final ProviderContainer container;
  final List<String> opened;

  ExportSaves get saves => container.read(exportSavesProvider.notifier);
}

_Rig _rig(
  _Target target, {
  required Future<http.StreamedResponse> Function(http.BaseRequest) handler,
  Completer<void>? opener,
}) {
  final opened = <String>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'u1',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 4102444800000,
          ),
        ),
      ),
      downloadTargetOpenerProvider.overrideWithValue((name) async {
        opened.add(name);
        await opener?.future;
        return target;
      }),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient.streaming((req, _) => handler(req)),
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  addTearDown(container.dispose);
  return _Rig(container, opened);
}

Future<http.StreamedResponse> _bytes(List<int> body) async =>
    http.StreamedResponse(
      Stream.value(body),
      200,
      contentLength: body.length,
      headers: {'content-type': 'application/x-tar'},
    );

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('a cancel before the headers arrive downloads nothing', () async {
    final target = _Target();
    final headers = Completer<void>();
    final rig = _rig(
      target,
      handler: (_) async {
        await headers.future;
        return _bytes([1, 2, 3, 4]);
      },
    );
    final save = rig.saves.start(_job);
    await _tick();
    await rig.saves.cancel('e1');
    headers.complete();
    await save;

    expect(target.finished, isFalse);
    expect(target.bytes, isEmpty);
    expect(target.discards, 1);
    expect(rig.container.read(exportSavesProvider), isEmpty);
  });

  test('leaving mid-save never completes a truncated archive', () async {
    final target = _Target();
    final body = StreamController<List<int>>();
    addTearDown(body.close);
    final rig = _rig(
      target,
      handler: (_) async => http.StreamedResponse(body.stream, 200),
    );
    final save = rig.saves.start(_job);
    await _tick();
    body.add([1, 2]);
    await _tick();
    rig.container.invalidate(exportSavesProvider);
    await _tick();
    unawaited(body.close());
    await save;

    expect(target.finished, isFalse);
    expect(target.discards, greaterThanOrEqualTo(1));
  });

  test('a second press while the destination opens starts nothing', () async {
    final target = _Target();
    final opener = Completer<void>();
    final rig = _rig(
      target,
      opener: opener,
      handler: (_) => _bytes([1, 2, 3, 4]),
    );
    final first = rig.saves.start(_job);
    final second = rig.saves.start(_job);
    opener.complete();
    await Future.wait([first, second]);

    expect(rig.opened, hasLength(1));
    expect(target.bytes, [1, 2, 3, 4]);
  });

  test('an archive bigger than the target holds fails up front', () async {
    final target = _Target(limit: 2);
    var requested = false;
    final rig = _rig(
      target,
      handler: (_) async {
        requested = true;
        return _bytes([1, 2, 3, 4]);
      },
    );
    await rig.saves.start(_job);

    expect(requested, isFalse);
    expect(target.discards, 1);
    final save = rig.container.read(exportSavesProvider)['e1']!;
    expect(save.phase, ExportSavePhase.failed);
    expect(save.message, contains('too large'));
  });

  test('a failed save leaves no file and says so', () async {
    final target = _Target();
    final rig = _rig(
      target,
      handler: (_) async => http.StreamedResponse(const Stream.empty(), 500),
    );
    await rig.saves.start(_job);

    expect(target.finished, isFalse);
    expect(target.discards, 1);
    expect(
      rig.container.read(exportSavesProvider)['e1']!.phase,
      ExportSavePhase.failed,
    );
  });

  test('one failed poll does not stop the refresh', () async {
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        exportPollIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 10),
        ),
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'u1',
              accessToken: 'a',
              refreshToken: 'r',
              accessExpiresAt: 4102444800000,
            ),
          ),
        ),
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              calls++;
              if (calls == 2) throw http.ClientException('offline');
              final status = calls < 3 ? 'running' : 'ready';
              return http.Response(
                jsonEncode([
                  {
                    'id': 'e1',
                    'kind': 'member',
                    'status': status,
                    'processed': 1,
                    'total': 2,
                    'created_at': 1,
                  },
                ]),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          );
          ref.onDispose(built.close);
          return built;
        }),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(dataExportsProvider, (_, _) {});
    addTearDown(sub.close);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final jobs = container.read(dataExportsProvider).valueOrNull;
    expect(jobs?.single.status, api.ExportStatus.ready);
  });
}
