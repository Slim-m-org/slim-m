// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A burst of pasted files never pushes the composer off screen: the tray
/// stops at the files one message carries, scrolls past a few rows, and says
/// why Send is waiting, with one control to clear every failed file.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart'
    show kMaxStagedAttachments;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../support/async_wait.dart';
import 'composer_harness.dart';

final _bytes = Uint8List.fromList([1, 2, 3, 4]);

/// Every upload is refused by the rate limit, as a tester's burst of 14 was.
api.SlimmApi _rateLimitedApi(Ref ref) => testApi(
  (request) async => http.Response(
    jsonEncode({'error': 'slow down'}),
    429,
    headers: {'content-type': 'application/json', 'retry-after': '30'},
  ),
  session: ref.watch(sessionProvider),
);

void main() {
  late TextEditingController controller;
  late FakeClipboardPaste paste;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    paste = FakeClipboardPaste();
  });

  tearDown(() => controller.dispose());

  Future<void> pumpPhone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: Sends(),
        platform: TargetPlatform.linux,
        clipboardPaste: paste,
        apiBuilder: _rateLimitedApi,
      ),
    );
    await tester.tap(find.byKey(const Key('composer-action-bar')));
    await tester.pump();
  }

  Future<void> pasteMany(WidgetTester tester, int count) async {
    for (var i = 0; i < count; i++) {
      paste.paste(_bytes, 'shot-$i.png');
      await tester.pump();
    }
    await pumpFrames(tester);
  }

  testWidgets('a file past the per-message limit is refused, in words', (
    tester,
  ) async {
    await pumpPhone(tester);
    await pasteMany(tester, kMaxStagedAttachments + 2);

    expect(find.text('shot-${kMaxStagedAttachments - 1}.png'), findsOneWidget);
    expect(find.text('shot-$kMaxStagedAttachments.png'), findsNothing);
    expect(
      find.textContaining('one message holds up to $kMaxStagedAttachments'),
      findsOneWidget,
    );
  });

  testWidgets('a full tray scrolls and leaves the field on screen', (
    tester,
  ) async {
    await pumpPhone(tester);
    await pasteMany(tester, kMaxStagedAttachments);

    final tray = tester.getRect(
      find.byKey(const Key('composer-attachment-tray')),
    );
    expect(tray.height, lessThanOrEqualTo(844 * 0.25));
    final bar = tester.getRect(find.byKey(const Key('composer-action-bar')));
    expect(bar.top, greaterThan(844 / 2));
    expect(bar.bottom, lessThanOrEqualTo(844));
  });

  testWidgets('failed files say why Send waits, and clear in one tap', (
    tester,
  ) async {
    await pumpPhone(tester);
    await pasteMany(tester, 3);

    expect(
      find.text('3 files did not upload. Retry or remove them to send.'),
      findsOneWidget,
    );
    expect(tester.widget<AppIconButton>(sendButton).onPressed, isNull);

    await tester.tap(find.text('Remove failed'));
    await pumpFrames(tester);

    expect(find.textContaining('did not upload'), findsNothing);
    expect(find.text('shot-0.png'), findsNothing);
  });
}
