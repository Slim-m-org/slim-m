// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An embed's painted height is the height its message row gives the next row.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart'
    show MessageExtras;
import 'package:slimm_app/src/features/messages/providers/link_preview.dart'
    show linkPreviewImageBytesProvider;
import 'package:slimm_app/src/features/messages/widgets/embed_card.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';

import 'package:slimm_design_system/design_system.dart' show AppSpacing;

import '../../ui_snapshot_support.dart' show loadRealFonts;
import 'message_row_harness.dart';

const _title =
    'karrigan: "We can\'t win our own map pick lately" and more words';

MessageRow _row(String id, bool grouped, List<api.Embed> embeds) => MessageRow(
  key: ValueKey(id),
  message: message(id: id, content: ''),
  grouped: grouped,
  showNewDivider: false,
  knownUsernames: const {},
  actions: noActions,
  editing: false,
  callbacks: MessageRowCallbacks(
    onRetry: () {},
    onDiscard: () {},
    onPickReaction: (_) {},
    onReactionTap: (_) {},
    onVote: (_) {},
    onSubmitEdit: (_) {},
    onCancelEdit: () {},
  ),
  extras: MessageExtras(embeds: embeds),
);

void main() {
  setUpAll(loadRealFonts);

  for (final width in [420.0, 700.0, 1100.0]) {
    testWidgets('the next row starts below the embed at ${width}px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const embed = api.Embed(
        title: _title,
        url: 'https://example.com/a',
        accent: api.EmbedAccent.blue,
        footerText: 'HLTV.org - The home of competitive Counter-Strike',
        timestamp: 1700000000000,
      );
      await tester.pumpWidget(
        harness(
          ListView(
            children: [
              _row('a', false, const [embed]),
              _row('b', true, const []),
            ],
          ),
        ),
      );
      await tester.pump();

      final card = tester.getRect(find.byType(EmbedCard));
      final next = tester.getRect(find.byKey(const ValueKey('b')));
      expect(card.bottom, lessThanOrEqualTo(next.top));
      final footer = tester.getRect(find.textContaining('HLTV.org'));
      expect(footer.bottom, lessThanOrEqualTo(card.bottom));
      expect(card.bottom - footer.bottom, AppSpacing.s12);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [
    const Size(800, 420),
    const Size(120, 120),
    const Size(300, 900),
  ]) {
    testWidgets(
      'the next row waits for a late ${size.width}x${size.height} image',
      (tester) async {
        tester.view.physicalSize = const Size(900, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final bytes = Completer<Uint8List?>();
        const embed = api.Embed(
          title: _title,
          thumbnailToken: 'tok',
          accent: api.EmbedAccent.blue,
          footerText: 'HLTV.org',
          timestamp: 1700000000000,
        );
        await tester.pumpWidget(
          harness(
            ListView(
              children: [
                _row('a', false, const [embed]),
                _row('b', true, const []),
              ],
            ),
            overrides: [
              linkPreviewImageBytesProvider(
                'tok',
              ).overrideWith((ref) => bytes.future),
            ],
          ),
        );
        await tester.pump();
        final png = await tester.runAsync(() => _png(size));
        bytes.complete(png);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();

        final card = tester.getRect(find.byType(EmbedCard));
        final next = tester.getRect(find.byKey(const ValueKey('b')));
        expect(card.bottom, lessThanOrEqualTo(next.top));
        expect(
          tester.getRect(find.byType(Image)).bottom,
          lessThanOrEqualTo(card.bottom),
        );
        final footer = tester.getRect(find.textContaining('HLTV.org'));
        expect(footer.bottom, lessThanOrEqualTo(card.bottom));
        // Sized by its content: no blank band below the footer, whatever the image's size.
        expect(card.bottom - footer.bottom, AppSpacing.s12);
      },
    );
  }
}

Future<Uint8List> _png(Size size) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(
    recorder,
  ).drawRect(Offset.zero & size, ui.Paint()..color = const Color(0xFF3366CC));
  final image = await recorder.endRecording().toImage(
    size.width.toInt(),
    size.height.toInt(),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
