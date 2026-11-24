// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An attachment image declaring a huge canvas says it is too large instead of decoding it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/declared_size_png.dart';

const _attachment = api.Attachment(
  id: 'big1',
  filename: 'big.png',
  contentType: 'image/png',
  size: 300000,
);

void main() {
  testWidgets('a 12000 x 12000 png shows the too-large state', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final bytes = solidPng(12000, 12000);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWith(
            (ref) => SharedPreferences.getInstance(),
          ),
          attachmentPreviewBytesProvider.overrideWith(
            (ref, key) async => bytes,
          ),
          attachmentBytesProvider(
            _attachment.id,
          ).overrideWith((ref) async => bytes),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: AttachmentView(attachment: _attachment),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump();
    }
    expect(find.text('Too large to show'), findsOneWidget);
  });
}
