// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The forward picker draws each channel with the glyph the rail gives it: a
/// lock for a private channel, a speaker for a voice one, a hash otherwise,
/// and Notes the notebook rather than a letter avatar.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/forward_targets.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/messages/widgets/destination_picker.dart';
import 'package:slimm_app/src/features/messages/widgets/forward_message.dart';
import 'package:slimm_data/data.dart' as data;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_sync.dart';

const _source = data.Message(
  id: 'm1',
  channelId: 'c1',
  authorId: 'alice',
  authorDisplayName: 'Alice',
  seq: 1,
  content: 'hi',
  createdAt: 1000,
  pending: false,
  failed: false,
);

List<IconData> _glyphsOf(WidgetTester tester, String channelId) {
  final row = find.byKey(DestinationPicker.rowKey(channelId));
  return [
    for (final icon in tester.widgetList<Icon>(
      find.descendant(of: row, matching: find.byType(Icon)),
    ))
      // The highlighted row's Enter keycap is not the row's glyph.
      if (icon.icon != AppIcons.enterKey) icon.icon!,
  ];
}

void main() {
  testWidgets('private and voice channels get the rail glyphs, not a hash', (
    tester,
  ) async {
    final db = data.SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        storeProvider.overrideWith((ref) async => data.MessageStore(db)),
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
        forwardTargetsProvider.overrideWith(
          (ref, query) async => const [
            ForwardTarget(channelId: 'a', label: 'general', isDm: false),
            ForwardTarget(
              channelId: 'b',
              label: 'secret',
              isDm: false,
              restricted: true,
            ),
            ForwardTarget(
              channelId: 'c',
              label: 'vc',
              isDm: false,
              isVoice: true,
            ),
            ForwardTarget(
              channelId: 'n',
              label: 'Notes',
              isDm: true,
              isPersonalSpace: true,
              userId: 'me',
            ),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ElevatedButton(
                onPressed: () => forwardMessage(context, ref, _source),
                child: const Text('Forward'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Forward'));
    await tester.pumpAndSettle();

    expect(_glyphsOf(tester, 'a'), [AppIcons.hash]);
    expect(_glyphsOf(tester, 'b'), [AppIcons.hash, AppIcons.restrictedChannel]);
    expect(_glyphsOf(tester, 'c'), [AppIcons.voice]);
    expect(_glyphsOf(tester, 'n'), [AppIcons.notebook]);
  });
}
