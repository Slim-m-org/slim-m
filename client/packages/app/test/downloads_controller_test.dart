// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Downloads run from an app-scoped controller: they stream to the chosen
/// target, report progress, survive the widgets that started them, and a
/// cancel stops the request and removes the partial file.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/downloads/downloads_controller.dart';
import 'package:slimm_app/src/downloads/transfers_banner.dart';
import 'package:slimm_design_system/design_system.dart';

import 'downloads_harness.dart';

const _iso = api.Attachment(
  id: 'iso1',
  filename: 'Win11.iso',
  contentType: 'application/octet-stream',
  size: 8,
);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late FakeAttachmentServer server;
  late FakeSaveDialog dialog;
  late ProviderContainer container;

  // Built inside each test, not setUp: a widget test's fake-async zone must own the stream.
  void harness({int status = 200}) {
    server = FakeAttachmentServer(status: status, contentLength: 8);
    dialog = FakeSaveDialog();
    container = downloadsContainer(server, dialog);
    addTearDown(container.dispose);
    container.listen(downloadsProvider, (_, _) {});
  }

  DownloadsController controller() =>
      container.read(downloadsProvider.notifier);
  List<DownloadTask> tasks() => container.read(downloadsProvider);

  test('streams every chunk to the target and finishes', () async {
    harness();
    final started = controller().start(_iso);
    await _settle();
    server.body.add([1, 2, 3, 4]);
    await _settle();
    expect(tasks().single.running, isTrue);
    server.body.add([5, 6, 7, 8]);
    await server.body.close();
    await started;

    final target = dialog.targets.single;
    expect(target.bytes, [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(target.finished, isTrue);
    expect(tasks().single.phase, DownloadPhase.done);
    expect(tasks().single.received, 8);
    expect(dialog.filenames, ['Win11.iso']);
  });

  test('a dismissed Save dialog starts nothing', () async {
    harness();
    dialog.dismiss = true;
    await controller().start(_iso);
    expect(tasks(), isEmpty);
    expect(server.requests, 0);
  });

  test('the same attachment is not downloaded twice at once', () async {
    harness();
    unawaited(controller().start(_iso));
    await _settle();
    await controller().start(_iso);
    expect(tasks(), hasLength(1));
    expect(server.requests, 1);
  });

  test('cancel closes the response and deletes the partial file', () async {
    harness();
    unawaited(controller().start(_iso));
    await _settle();
    server.body.add([1, 2, 3]);
    await _settle();

    await controller().cancel(tasks().single.id);

    expect(server.bodyCancelled, isTrue);
    expect(dialog.targets.single.discarded, isTrue);
    expect(dialog.targets.single.finished, isFalse);
    expect(tasks(), isEmpty);
  });

  test('a refused download fails with a sentence and leaves no file', () async {
    harness(status: 403);

    await controller().start(_iso);

    final task = tasks().single;
    expect(task.phase, DownloadPhase.failed);
    expect(task.message, contains('Could not download Win11.iso'));
    expect(dialog.targets.single.discarded, isTrue);
  });

  test(
    'a connection that dies mid-body fails and deletes the partial',
    () async {
      harness();
      unawaited(controller().start(_iso));
      await _settle();
      server.body.add([1, 2]);
      server.body.addError(const api.TransportException('reset'));
      await _settle();

      expect(tasks().single.phase, DownloadPhase.failed);
      expect(dialog.targets.single.discarded, isTrue);
    },
  );

  Future<ValueNotifier<String>> pumpApp(WidgetTester tester) async {
    final channel = ValueNotifier('a');
    addTearDown(channel.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: TransfersBannerHost(
              child: ValueListenableBuilder<String>(
                valueListenable: channel,
                builder: (context, id, _) => id == 'a'
                    ? Consumer(
                        key: const ValueKey('channel-a'),
                        builder: (context, ref, _) => TextButton(
                          onPressed: () =>
                              ref.read(downloadsProvider.notifier).start(_iso),
                          child: const Text('save'),
                        ),
                      )
                    : const Text('channel b', key: ValueKey('channel-b')),
              ),
            ),
          ),
        ),
      ),
    );
    return channel;
  }

  testWidgets('a download carries on, and stays on screen, when the widget '
      'that started it goes away (a channel switch)', (tester) async {
    harness();
    final channel = await pumpApp(tester);
    await tester.tap(find.text('save'));
    await tester.pump(const Duration(milliseconds: 200));
    server.body.add([1, 2, 3, 4]);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text('Win11.iso'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    channel.value = 'b';
    await tester.pump();
    expect(find.text('channel b'), findsOneWidget);
    expect(
      find.text('Win11.iso'),
      findsOneWidget,
      reason: 'banner is app scope',
    );
    expect(dialog.targets.single.discarded, isFalse);
    expect(server.bodyCancelled, isFalse);

    server.body.add([5, 6, 7, 8]);
    unawaited(server.body.close());
    await tester.pump(const Duration(milliseconds: 200));
    expect(dialog.targets.single.bytes, hasLength(8));
    expect(dialog.targets.single.finished, isTrue);
    expect(find.text('Saved Win11.iso'), findsOneWidget);
  });

  testWidgets('Cancel in the banner stops the download and clears the row', (
    tester,
  ) async {
    harness();
    await pumpApp(tester);
    await tester.tap(find.text('save'));
    await tester.pump(const Duration(milliseconds: 200));
    server.body.add([1, 2]);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(server.bodyCancelled, isTrue);
    expect(dialog.targets.single.discarded, isTrue);
    expect(find.text('Win11.iso'), findsNothing);
  });

  testWidgets('a failed download stays as a red row with Retry, no SnackBar', (
    tester,
  ) async {
    harness(status: 403);
    await pumpApp(tester);

    await tester.tap(find.text('save'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
    expect(find.textContaining('Could not download Win11.iso'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
