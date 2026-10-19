// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A download just saves: no banner pushes the shell around, success is a
/// toast, and only a failure stays on screen, floating over the content.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/downloads/download_failures.dart';
import 'package:slimm_app/src/downloads/downloads_controller.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_design_system/design_system.dart';

import 'downloads_harness.dart';

const _iso = api.Attachment(
  id: 'iso1',
  filename: 'Win11.iso',
  contentType: 'application/octet-stream',
  size: 100,
);

void main() {
  late FakeAttachmentServer server;
  late FakeSaveDialog dialog;
  late ProviderContainer container;
  const contentKey = Key('shell-content');

  Future<void> pumpApp(WidgetTester tester) async {
    server = FakeAttachmentServer(contentLength: 100);
    dialog = FakeSaveDialog();
    container = downloadsContainer(server, dialog);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: DownloadFailureHost(
              child: Consumer(
                builder: (context, ref, _) => TextButton(
                  key: contentKey,
                  onPressed: () =>
                      ref.read(downloadsProvider.notifier).start(_iso),
                  child: const Text('save'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 200));

  testWidgets('a running download shows nothing and moves nothing', (
    tester,
  ) async {
    await pumpApp(tester);
    final before = tester.getTopLeft(find.byKey(contentKey));
    await tester.tap(find.text('save'));
    await settle(tester);
    server.body.add([1, 2, 3]);
    await settle(tester);

    expect(find.text('Win11.iso'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
    expect(tester.getTopLeft(find.byKey(contentKey)), before);

    unawaited(server.body.close());
    await settle(tester);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a finished download says so with a toast and no card', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('save'));
    await settle(tester);
    server.body.add([1]);
    unawaited(server.body.close());
    await settle(tester);

    expect(dialog.targets.single.finished, isTrue);
    expect(container.read(toastsProvider).map((t) => t.message), [
      'Saved Win11.iso.',
    ]);
    expect(find.byType(AppErrorState), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a failure floats over the content and Retry replaces it', (
    tester,
  ) async {
    await pumpApp(tester);
    dialog.make = () => FakeTarget()..failWrite = dialog.targets.isEmpty;
    final before = tester.getTopLeft(find.byKey(contentKey));
    await tester.tap(find.text('save'));
    await settle(tester);
    server.body.add([1]);
    await settle(tester);

    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Could not save Win11.iso.'), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(contentKey)), before);

    await tester.tap(find.text('Retry'));
    await settle(tester);
    await settle(tester);
    expect(server.requests, 2);
    expect(find.text('Could not save Win11.iso.'), findsNothing);

    unawaited(server.body.close());
    await settle(tester);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Dismiss clears a failure', (tester) async {
    await pumpApp(tester);
    dialog.make = () => FakeTarget()..failWrite = true;
    await tester.tap(find.text('save'));
    await settle(tester);
    server.body.add([1]);
    await settle(tester);
    expect(find.byType(AppErrorState), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await settle(tester);
    expect(find.byType(AppErrorState), findsNothing);
  });
}
