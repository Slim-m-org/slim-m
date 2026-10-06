// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/composer_attachment_drop.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/typing_controller.dart';
import 'package:slimm_app/src/widgets/composer.dart';
import 'package:slimm_app/src/widgets/composer_clipboard_image.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_harness.dart';

Widget _tree(Key key, TextEditingController c) => ProviderScope(
  overrides: [
    typingControllerProvider.overrideWith((ref, channelId) => NoopTyping()),
    sessionProvider.overrideWithValue(
      api.SessionStore(
        tokens: const api.TokenPair(
          userId: 'self',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
    ),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Column(
        children: [
          const Spacer(),
          Composer(
            key: key,
            controller: c,
            channelId: 'c1',
            channelName: 'general',
            onSend: (_) async {},
            clipboardPasteStart: startClipboardImagePaste,
            clipboardPasteStop: stopClipboardImagePaste,
          ),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('a same-frame remount keeps a drop target registered', (t) async {
    SharedPreferences.setMockInitialValues({});
    final c = TextEditingController();
    addTearDown(c.dispose);
    await t.pumpWidget(_tree(const ValueKey('a'), c));
    await t.pump();
    final container = ProviderScope.containerOf(
      t.element(find.byType(Composer)),
    );
    expect(container.read(composerAttachmentDropProvider('c1')), isNotNull);

    await t.pumpWidget(_tree(const ValueKey('b'), c));
    await t.pump();
    expect(
      container.read(composerAttachmentDropProvider('c1')),
      isNotNull,
      reason:
          'a Composer is on screen for c1, so a drop target must be registered',
    );
  });
}
