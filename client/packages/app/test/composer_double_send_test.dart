// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/composer_attachments.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'composer_attach_harness.dart';
import 'composer_harness.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('double click on send posts the attachment message once', (
    tester,
  ) async {
    usePicker(pickedFile());
    final posted = Posted();
    final gate = Completer<void>();
    await pumpChannel(
      tester,
      posted,
      messagePost: (r) async {
        await gate.future;
        return okMessage(r);
      },
    );
    await tester.tap(attachButton);
    await flush(tester);
    await tester.tap(sendButton);
    await flush(tester);
    await tester.tap(sendButton);
    await flush(tester);
    gate.complete();
    await flush(tester);
    expect(posted.bodies.length, 1, reason: 'one click-pair, one message');
    await unmount(tester);
  });

  testWidgets('double Enter posts the attachment message once', (tester) async {
    usePicker(pickedFile());
    final posted = Posted();
    final gate = Completer<void>();
    await pumpChannel(
      tester,
      posted,
      messagePost: (r) async {
        await gate.future;
        return okMessage(r);
      },
    );
    await tester.tap(attachButton);
    await flush(tester);
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await flush(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await flush(tester);
    gate.complete();
    await flush(tester);
    expect(posted.bodies.length, 1);
    await unmount(tester);
  });

  testWidgets('a send resolving after a channel switch keeps the new '
      "channel's staged file", (tester) async {
    usePicker(pickedFile());
    final gate = Completer<void>();
    final sends = _GatedSends(gate);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
      ),
    );
    await tester.tap(attachButton);
    await tester.pumpAndSettle();
    await tester.tap(sendButton);
    await tester.pump();
    await tester.pump();
    // Switch channel while the send for c1 is still in flight.
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        channelId: 'c2',
      ),
    );
    await tester.pump();
    await tester.tap(attachButton);
    await tester.pumpAndSettle();
    expect(find.text('holiday.png'), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(
      find.text('holiday.png'),
      findsOneWidget,
      reason: "c1's send resolving must not wipe c2's staged file",
    );
  });

  testWidgets('a text message typed while an attachment send is in flight '
      'still sends', (tester) async {
    usePicker(pickedFile());
    final gate = Completer<void>();
    final sends = _GatedSends(gate);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
      ),
    );
    await tester.tap(attachButton);
    await tester.pumpAndSettle();
    await tester.tap(sendButton);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'next');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sends.count, 2);
    expect(sends.ids, isEmpty);
    gate.complete();
    await tester.pumpAndSettle();
  });

  test(
    'a send refused before it is queued gives the staged file back',
    () async {
      final staging = AttachmentStagingController(
        upload: (_, _) => throw StateError('unused'),
      )..addResolved(_attachment, Uint8List(0));
      await expectLater(
        staging.sendReady((_) => throw StateError('store unavailable')),
        throwsStateError,
      );
      expect(staging.readyIds, ['a1']);
    },
  );

  test(
    'a second send while the first is in flight finds nothing staged',
    () async {
      final staging = AttachmentStagingController(
        upload: (_, _) => throw StateError('unused'),
      )..addResolved(_attachment, Uint8List(0));
      final gate = Completer<void>();
      final seen = <List<String>>[];
      Future<void> send(List<String> ids) async {
        seen.add(ids);
        await gate.future;
      }

      final first = staging.sendReady(send);
      await staging.sendReady((ids) async => seen.add(ids));
      gate.complete();
      await first;
      expect(seen, [
        ['a1'],
        <String>[],
      ]);
    },
  );
}

class _GatedSends extends Sends {
  _GatedSends(this.gate);
  final Completer<void> gate;
  @override
  Future<void> call(List<String> attachmentIds) async {
    count += 1;
    ids = attachmentIds;
    await gate.future;
  }
}

const _attachment = api.Attachment(
  id: 'a1',
  filename: 'holiday.png',
  contentType: 'image/png',
  size: 1,
);
