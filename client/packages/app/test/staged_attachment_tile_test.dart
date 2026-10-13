// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The staged-attachment tile's remove/retry buttons: a hover affordance and
/// a tap haptic, added 2026-09-03 after the owner found the X "doesn't look
/// noticeable" and gave no feedback on touch.
library;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/composer_attachments.dart';
import 'package:slimm_app/src/widgets/staged_attachment_tile.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(body: Center(child: child)),
);

UploadedAttachment _staged() => UploadedAttachment(
  localId: 'a1',
  filename: 'notes.pdf',
  body: AttachmentBody.memory(Uint8List.fromList(const [0])),
  attachment: const api.Attachment(
    id: 'srv-1',
    filename: 'notes.pdf',
    contentType: 'application/pdf',
    size: 1,
  ),
);

Finder _removeButton() => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == 'Remove attachment notes.pdf',
);

void main() {
  testWidgets('tapping remove fires a selection haptic and calls onRemove', (
    tester,
  ) async {
    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments as String? ?? 'default');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    var removed = false;
    await tester.pumpWidget(
      _harness(
        StagedAttachmentTile(
          attachment: _staged(),
          onRemove: () => removed = true,
          onRetry: () {},
        ),
      ),
    );

    await tester.tap(_removeButton());
    await tester.pump();

    expect(removed, isTrue);
    expect(
      haptics,
      contains('HapticFeedbackType.selectionClick'),
      reason: 'a touch device should confirm the removal',
    );
  });

  testWidgets('the remove button lights a background on hover', (tester) async {
    await tester.pumpWidget(
      _harness(
        StagedAttachmentTile(
          attachment: _staged(),
          onRemove: () {},
          onRetry: () {},
        ),
      ),
    );

    Color? fillUnder(Finder button) {
      final container = tester.widget<Container>(
        find.descendant(of: button, matching: find.byType(Container)).first,
      );
      return (container.decoration as BoxDecoration?)?.color;
    }

    const tokens = AppTokens.light;
    expect(fillUnder(_removeButton()), Colors.transparent);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(_removeButton()));
    await tester.pump();

    expect(fillUnder(_removeButton()), tokens.surfaceSunken);
  });
}
