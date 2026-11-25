// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A browser download of an attachment or export goes through a signed link, so a file past
/// the in-memory cap still saves and nothing is streamed through the app.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/downloads/download_target.dart';
import 'package:slimm_app/src/downloads/downloads_controller.dart';
import 'package:slimm_app/src/features/settings/providers/data_export_download.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../downloads_harness.dart';

class _LinkTarget extends FakeTarget implements LinkDownloadTarget {
  final links = <(Uri, String)>[];

  @override
  int? get maxBytes => kMemoryDownloadLimit;

  @override
  Future<void> openLink(Uri link, String filename) async =>
      links.add((link, filename));
}

const _huge = api.Attachment(
  id: 'iso1',
  filename: 'Win11.iso',
  contentType: 'application/octet-stream',
  size: 3 * 1024 * 1024 * 1024,
);

const _export = api.DataExport(
  id: 'e1',
  kind: api.ExportKind.member,
  status: api.ExportStatus.ready,
  processed: 1,
  total: 1,
  createdAt: 1767225600000,
  sizeBytes: 3 * 1024 * 1024 * 1024,
);

ProviderContainer _container(
  _LinkTarget target,
  List<http.BaseRequest> seen, {
  int status = 200,
}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: testTokens)),
      downloadTargetOpenerProvider.overrideWithValue((_) async => target),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient.streaming((request, _) async {
            seen.add(request);
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  jsonEncode({'path': '/downloads/tok.sig', 'expires_at': 9}),
                ),
              ),
              status,
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
  return container;
}

void main() {
  test('an attachment past the memory cap downloads from a link', () async {
    final target = _LinkTarget();
    final seen = <http.BaseRequest>[];
    final container = _container(target, seen);
    container.listen(downloadsProvider, (_, _) {});

    await container.read(downloadsProvider.notifier).start(_huge);

    expect(seen.single.url.path, '/downloads/links');
    expect(target.links.single.$1.path, '/downloads/tok.sig');
    expect(target.links.single.$2, 'Win11.iso');
    expect(target.bytes, isEmpty, reason: 'no byte passes through the app');
    expect(container.read(downloadsProvider), isEmpty, reason: 'no refusal');
  });

  test('a link that cannot be made leaves a failed row to retry', () async {
    final target = _LinkTarget();
    final container = _container(target, [], status: 404);
    container.listen(downloadsProvider, (_, _) {});

    await container.read(downloadsProvider.notifier).start(_huge);

    expect(
      container.read(downloadsProvider).single.phase,
      DownloadPhase.failed,
    );
    expect(target.links, isEmpty);
  });

  test('an export past the memory cap downloads from a link', () async {
    final target = _LinkTarget();
    final seen = <http.BaseRequest>[];
    final container = _container(target, seen);
    container.listen(exportSavesProvider, (_, _) {});

    await container.read(exportSavesProvider.notifier).start(_export);

    expect(seen.single.url.path, '/downloads/links');
    expect(
      (seen.single as http.Request).body,
      jsonEncode({'kind': 'export', 'id': 'e1'}),
    );
    expect(target.links.single.$2, matches(r'^slimm-member-export-.*\.tar$'));
    expect(
      container.read(exportSavesProvider)['e1']?.phase,
      ExportSavePhase.done,
    );
  });
}
