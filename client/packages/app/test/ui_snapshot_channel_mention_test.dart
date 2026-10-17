// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel mention inside a bot message, known and unknown, at phone and
/// desktop width in the dark theme. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise this asserts a clean layout.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/providers/code_block_runner.dart';
import 'package:slimm_app/src/widgets/message_text.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';

const _id = '0190a3f2-7c1e-7a55-9b0d-3f2a6c1d8e44';
const _gone = '0190a3f2-7c1e-7a55-9b0d-3f2a6c1d8e45';

void main() {
  setUpAll(loadRealFonts);
  const sizes = {'phone': Size(390, 140), 'desktop': Size(900, 110)};
  for (final entry in sizes.entries) {
    testWidgets('channel mention ${entry.key} (dark)', (tester) async {
      tester.view.physicalSize = entry.value;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            codeBlockRunnerProvider.overrideWith((ref) async => const []),
            channelByIdProvider.overrideWith(
              (ref, id) => Stream.value(
                id == _id
                    ? const Channel(
                        id: _id,
                        name: 'ticket-0001',
                        kind: 'text',
                        createdAt: 0,
                        position: 0,
                        cursor: 0,
                        lastReadSeq: 0,
                        mentionedSeq: 0,
                        slowModeSeconds: 0,
                        joinMuted: false,
                        isPersonalSpace: false,
                      )
                    : null,
              ),
            ),
          ],
          child: RepaintBoundary(
            key: snapshotBoundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(Brightness.dark, AppTokens.dark),
              home: const Scaffold(
                body: Padding(
                  padding: EdgeInsets.all(AppSpacing.s16),
                  child: MessageBody(
                    content:
                        'Your ticket is open: <#$_id>. Moved from <#$_gone>.',
                    knownUsernames: {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('#ticket-0001'), findsOneWidget);
      expect(find.text('#unknown-channel'), findsOneWidget);
      await writeSnapshot(tester, 'channel-mention-${entry.key}-dark');
    });
  }
}
