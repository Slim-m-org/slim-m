// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An inline image that is slow or fails to load is never invisible: it shows
/// a sized box naming the file, then a failure box with a Retry, and
/// transient failures retry by themselves. Driven through the real
/// transport with a fake HTTP client, so status codes map the way they do live.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/attachment_bytes.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/widgets/attachment_gallery.dart';
import 'package:slimm_app/src/widgets/attachment_image_states.dart';
import 'package:slimm_design_system/design_system.dart';
import 'support/fake_sync.dart';

const _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.Attachment _image(int i) => api.Attachment(
  id: 'img-$i',
  filename: 'photo-$i.png',
  contentType: 'image/png',
  size: 4,
);

const _delays = [Duration(seconds: 1), Duration(seconds: 3)];

/// Answers each request with the next handler, repeating the last one.
class _Server {
  _Server(this.handlers);

  final List<Future<http.Response> Function()> handlers;
  int requests = 0;

  Future<http.Response> handle(http.Request _) {
    final i = requests < handlers.length ? requests : handlers.length - 1;
    requests++;
    return handlers[i]();
  }
}

Future<http.Response> _status(int code, {String body = ''}) async =>
    http.Response(body, code);

Future<http.Response> _ok() async =>
    http.Response.bytes(Uint8List.fromList(_png), 200);

final _shown = ValueNotifier<bool>(true);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Server server, {
  List<api.Attachment>? attachments,
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _shown.value = true;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        attachmentRetryDelaysProvider.overrideWithValue(_delays),
        syncControllerProvider.overrideWith(NoopSyncController.new),
        apiProvider.overrideWith(
          (ref) => api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient(server.handle),
          ),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: _shown,
            builder: (context, shown, _) => shown
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: MessageAttachments(
                      attachments: attachments ?? [_image(0)],
                    ),
                  )
                : const SizedBox(),
          ),
        ),
      ),
    ),
  );
  return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
}

/// Lets a hanging request finish so its transport deadline timer is cleared.
Future<void> _release(
  WidgetTester tester,
  Completer<http.Response> hang,
) async {
  hang.complete(http.Response('', 403));
  _shown.value = false;
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('while the fetch hangs, a sized box names the file', (
    tester,
  ) async {
    final hang = Completer<http.Response>();
    await _pump(tester, _Server([() => hang.future]));
    await tester.pump(const Duration(seconds: 5));

    expect(find.text('Loading'), findsOneWidget);
    expect(find.textContaining('photo-0.png'), findsOneWidget);
    final box = tester.getRect(find.byType(AttachmentLoadingBox));
    expect(box.height, kImagePlaceholderHeight);
    expect(box.width, 358);
    expect(find.bySemanticsLabel('Loading photo-0.png'), findsOneWidget);
    await _release(tester, hang);
  });

  testWidgets('gallery tiles hold their square while loading', (tester) async {
    final hang = Completer<http.Response>();
    await _pump(
      tester,
      _Server([() => hang.future]),
      attachments: [_image(0), _image(1)],
    );
    await tester.pump();

    final boxes = tester
        .widgetList<AttachmentLoadingBox>(find.byType(AttachmentLoadingBox))
        .toList();
    expect(boxes, hasLength(2));
    for (final box in boxes) {
      final rect = tester.getRect(find.byWidget(box));
      expect(rect.width, box.tileEdge);
      expect(rect.height, box.tileEdge);
    }
    expect(find.textContaining('photo-1.png'), findsOneWidget);
    await _release(tester, hang);
  });

  testWidgets('a 404 shows the failure box and is not retried', (tester) async {
    final server = _Server([() => _status(404, body: '{"error":"gone"}')]);
    await _pump(tester, server);
    await tester.pump(const Duration(seconds: 30));

    expect(find.text('Could not load'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(server.requests, 1);
  });

  testWidgets('Retry refetches and the image appears', (tester) async {
    final server = _Server([() => _status(403, body: '{"error":"no"}'), _ok]);
    await _pump(tester, server);
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();

    expect(server.requests, 2);
    expect(find.text('Retry'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('a transient failure retries with backoff, then succeeds', (
    tester,
  ) async {
    final server = _Server([
      () => throw const api.TransportException('offline'),
      () => _status(502),
      _ok,
    ]);
    await _pump(tester, server);
    await tester.pump();
    expect(server.requests, 1);
    expect(find.text('Loading'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 900));
    expect(server.requests, 1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(server.requests, 2);

    await tester.pump(const Duration(seconds: 2));
    expect(server.requests, 2);
    await tester.pump(const Duration(seconds: 2));
    expect(server.requests, 3);
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('retries stop after the schedule and the failure box shows', (
    tester,
  ) async {
    final server = _Server([() => _status(500)]);
    await _pump(tester, server);
    await tester.pump(const Duration(seconds: 10));

    expect(server.requests, _delays.length + 1);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a failed fetch is not replayed to the next view of the image', (
    tester,
  ) async {
    final server = _Server([() => _status(403, body: '{"error":"no"}'), _ok]);
    await _pump(tester, server);
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);

    _shown.value = false;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    _shown.value = true;
    await tester.pump();
    await tester.pump();

    expect(find.text('Retry'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(server.requests, 2);
  });

  testWidgets('the socket coming back retries a failed image', (tester) async {
    final server = _Server([() => _status(403, body: '{"error":"no"}'), _ok]);
    final container = await _pump(tester, server);
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);

    (container.read(syncControllerProvider.notifier) as NoopSyncController)
      ..report(SyncStatus.offline)
      ..report(SyncStatus.live);
    await tester.pump();
    await tester.pump();

    expect(server.requests, 2);
    expect(find.byType(Image), findsOneWidget);
  });
}
