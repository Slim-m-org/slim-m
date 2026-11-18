// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Files dropped while a voice message records can fill the tray; Send then
/// keeps the clip and says why, rather than posting the files without it.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/providers/voice_recording.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_voice_bar.dart';

import 'composer_harness.dart';
import 'voice_recording_test.dart' show FakeCapture;

final _record = find.byTooltip('Record a voice message');
final _sendVoice = find.byTooltip('Send voice message');

Finder get _heldBack => find.descendant(
  of: find.byKey(const Key('composer-voice-bar')),
  matching: find.text(kVoiceTrayFullRefusal),
);

class _Recording {
  _Recording(this.tester, {api.SlimmApi Function(Ref)? apiBuilder})
    : _apiBuilder = apiBuilder;

  final WidgetTester tester;
  final api.SlimmApi Function(Ref)? _apiBuilder;
  final sends = Sends();
  late final AttachmentStagingController staging;

  Future<void> start() async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final capture = FakeCapture();
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: _apiBuilder,
        extraOverrides: [
          voiceCaptureFactoryProvider.overrideWithValue(() => capture),
        ],
      ),
    );
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('composer-action-bar'))),
    );
    var clock = DateTime(2026, 1, 1);
    container.read(voiceRecorderProvider('c1').notifier).now = () => clock;
    staging = container.read(attachmentStagingProvider('c1'));
    await tester.pump(ComposerMicButton.wakeDelay);
    await tester.tap(_record);
    await tester.pump();
    clock = clock.add(const Duration(seconds: 3));
  }

  void fillTray() {
    for (var i = staging.items.length; i < kMaxStagedAttachments; i++) {
      staging.addResolved(
        api.Attachment(
          id: 'f$i',
          filename: 'notes-$i.txt',
          contentType: 'text/plain',
          size: 4,
        ),
        Uint8List(4),
      );
    }
  }

  Future<void> tapSend() async {
    await tester.tap(_sendVoice);
    await tester.pump();
    await tester.pump();
  }

  /// Takes a file out and sends again, which now carries the clip.
  Future<void> makeRoomAndSend() async {
    staging.remove(staging.items.first.localId);
    await tester.pump();
    await tapSend();
    expect(sends.count, 1);
    expect(sends.ids, hasLength(kMaxStagedAttachments));
    expect(sends.ids, contains('a1'), reason: 'the clip goes with the files');
  }
}

void main() {
  testWidgets('a tray filled while recording holds the clip back', (
    tester,
  ) async {
    final upload = Completer<void>();
    final recording = _Recording(tester, apiBuilder: gatedUploadApi(upload));
    await recording.start();
    recording.fillTray();
    await tester.pump();

    await recording.tapSend();

    expect(recording.sends.count, 0, reason: 'the files never go alone');
    expect(_heldBack, findsOneWidget, reason: 'refused before any upload');
    expect(recording.staging.items, hasLength(kMaxStagedAttachments));
    upload.complete();
    await recording.makeRoomAndSend();
  });

  testWidgets('a tray filled during the upload holds the clip back too', (
    tester,
  ) async {
    final upload = Completer<void>();
    final recording = _Recording(tester, apiBuilder: gatedUploadApi(upload));
    await recording.start();
    await tester.tap(_sendVoice);
    await tester.pump();
    expect(find.text('Sending'), findsOneWidget);

    recording.fillTray();
    upload.complete();
    await tester.pump();
    await tester.pump();

    expect(recording.sends.count, 0, reason: 'the files never go alone');
    expect(_heldBack, findsOneWidget);
    await recording.makeRoomAndSend();
  });
}
