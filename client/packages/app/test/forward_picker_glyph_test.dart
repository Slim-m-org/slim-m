// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The forward picker draws each channel with the glyph the rail gives it: a
/// lock for a private channel, a speaker for a voice one, a hash otherwise.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/forward_targets.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/widgets/forward_message.dart';
import 'package:slimm_data/data.dart' as data;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

class _NoopSyncController extends SyncController {
  _NoopSyncController(super.ref);

  @override
  Future<void> start() async {}
}

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

List<IconData> _glyphsOf(WidgetTester tester, String label) {
  final row = find.ancestor(
    of: find.text(label),
    matching: find.byType(AppListRow),
  );
  return [
    for (final icon in tester.widgetList<Icon>(
      find.descendant(of: row, matching: find.byType(Icon)),
    ))
      icon.icon!,
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
        syncControllerProvider.overrideWith((ref) => _NoopSyncController(ref)),
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

    expect(_glyphsOf(tester, 'general'), [AppIcons.hash]);
    expect(_glyphsOf(tester, 'secret'), [
      AppIcons.hash,
      AppIcons.restrictedChannel,
    ]);
    expect(_glyphsOf(tester, 'vc'), [AppIcons.voice]);
  });
}
