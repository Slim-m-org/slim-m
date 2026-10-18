// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The transfers banner: app scope, live speed and time left, Cancel, Retry.
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

const _mib = 1024 * 1024;
const _iso = api.Attachment(
  id: 'iso1',
  filename: 'Win11.iso',
  contentType: 'application/octet-stream',
  size: 100 * _mib,
);

class _Clock {
  DateTime now = DateTime(2026, 10, 16, 12);
  DateTime call() => now;
}

void main() {
  late FakeAttachmentServer server;
  late FakeSaveDialog dialog;
  late ProviderContainer container;
  late _Clock clock;

  Future<ValueNotifier<String>> pumpApp(WidgetTester tester) async {
    server = FakeAttachmentServer(contentLength: 100 * _mib);
    dialog = FakeSaveDialog();
    clock = _Clock();
    container = downloadsContainer(server, dialog, clock: clock.call);
    addTearDown(container.dispose);
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
                        builder: (context, ref, _) => TextButton(
                          onPressed: () =>
                              ref.read(downloadsProvider.notifier).start(_iso),
                          child: const Text('save'),
                        ),
                      )
                    : const Text('channel b'),
              ),
            ),
          ),
        ),
      ),
    );
    return channel;
  }

  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 200));

  /// Feeds [chunks] one-MiB chunks, one clock second apart.
  Future<void> feed(WidgetTester tester, int chunks) async {
    for (var i = 0; i < chunks; i++) {
      clock.now = clock.now.add(const Duration(seconds: 1));
      server.body.add(List.filled(_mib, 1));
      await settle(tester);
    }
  }

  testWidgets('shows speed and time left, and a stall decays the rate', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('save'));
    await settle(tester);
    await feed(tester, 5);

    expect(find.textContaining('MB/s'), findsOneWidget);
    expect(find.textContaining('left'), findsOneWidget);
    final live = tester.widget<Text>(find.textContaining('MB/s')).data;

    clock.now = clock.now.add(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 1));
    final stalled = tester.widget<Text>(find.textContaining('/s')).data;
    expect(stalled, isNot(live));

    await tester.tap(find.text('Cancel'));
    await settle(tester);
  });

  testWidgets('an unfocused app stops refreshing the speed readout', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('save'));
    await settle(tester);
    await feed(tester, 5);
    final live = tester.widget<Text>(find.textContaining('MB/s')).data;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    clock.now = clock.now.add(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<Text>(find.textContaining('/s')).data, live);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<Text>(find.textContaining('/s')).data, isNot(live));

    await tester.tap(find.text('Cancel'));
    await settle(tester);
  });

  testWidgets('a download carries on, and stays on screen, when the widget '
      'that started it goes away (a channel switch)', (tester) async {
    final channel = await pumpApp(tester);
    await tester.tap(find.text('save'));
    await settle(tester);
    server.body.add([1, 2, 3, 4]);
    await settle(tester);
    expect(find.text('Win11.iso'), findsOneWidget);

    channel.value = 'b';
    await tester.pump();
    expect(find.text('channel b'), findsOneWidget);
    expect(find.text('Win11.iso'), findsOneWidget);
    expect(dialog.targets.single.discarded, isFalse);
    expect(server.bodyCancelled, isFalse);

    unawaited(server.body.close());
    await settle(tester);
    expect(dialog.targets.single.finished, isTrue);
    expect(find.text('Saved Win11.iso'), findsOneWidget);
  });

  testWidgets('Cancel stops the download and clears the row', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('save'));
    await settle(tester);
    server.body.add([1, 2]);
    await settle(tester);

    await tester.tap(find.text('Cancel'));
    await settle(tester);

    expect(server.bodyCancelled, isTrue);
    expect(dialog.targets.single.discarded, isTrue);
    expect(find.text('Win11.iso'), findsNothing);
  });

  testWidgets('tapping Retry downloads again and replaces the failed row', (
    tester,
  ) async {
    await pumpApp(tester);
    dialog.make = () => FakeTarget()..failWrite = dialog.targets.isEmpty;
    await tester.tap(find.text('save'));
    await settle(tester);
    server.body.add([1]);
    await settle(tester);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Could not save Win11.iso.'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await settle(tester);
    await settle(tester);

    expect(server.requests, 2);
    expect(dialog.targets, hasLength(2));
    expect(find.text('Could not save Win11.iso.'), findsNothing);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await settle(tester);
  });
}
