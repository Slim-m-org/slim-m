// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A 1 px image still gets a box a reader can see and tap, with its own pixels left at their size.
/// A break-it tester's 1x1 png drew as a single dot above its caption.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';

const _tiny = api.Attachment(
  id: 't1',
  filename: 'tiny1x1.png',
  contentType: 'image/png',
  size: 69,
);

final _onePixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60'
  'e6kgAAAABJRU5ErkJggg==',
);

void main() {
  testWidgets('a 1x1 image sits in a fingertip-sized box at its own size', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWith(
          (ref) => SharedPreferences.getInstance(),
        ),
        attachmentPreviewBytesProvider.overrideWith(
          (ref, key) async => Uint8List.fromList(_onePixel),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: AttachmentView(attachment: _tiny),
            ),
          ),
        ),
      ),
    );
    await pumpFrames(tester);

    final image = find.bySemanticsLabel('tiny1x1.png');
    expect(image, findsOneWidget);
    final box = tester.getRect(image);
    expect(box.width, greaterThanOrEqualTo(AppSizes.rowTouch));
    expect(box.height, greaterThanOrEqualTo(AppSizes.rowTouch));
    final raw = tester.widget<RawImage>(
      find.byWidgetPredicate((w) => w is RawImage),
    );
    expect(raw.fit, BoxFit.scaleDown, reason: 'one pixel is not blown up');
  });
}
