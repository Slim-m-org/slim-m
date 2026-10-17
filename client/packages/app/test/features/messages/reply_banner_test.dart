// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The staged-reply strip above the composer: it names who a reply targets and
/// a one-line snippet, and cancels back to an ordinary send. A text-less parent
/// is named by what it carried instead, so replying to a photo is not a blank
/// "Replying to". A text-less, single-attachment parent also swaps the leading
/// reply arrow for a compact thumbnail: a decoded image for a photo, a file
/// glyph for anything else, and the file glyph again when auto-download is
/// off, so the banner never blocks on a fetch it was not asked to make. Under
/// SLIMM_UI_SNAPSHOTS it also writes a picture of the cases so the shape is
/// looked at, not only asserted.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/messages/providers/media_preferences.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/messages/widgets/reply_banner.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';
import '../../ui_snapshot_support.dart';

/// Seeds [messageExtrasProvider] with what a parent carried, the way a live
/// frame or a REST page would, without a socket: the controller reads the
/// event stream at build, so an empty one keeps it inert.
List<Override> _carrying(
  String messageId,
  List<api.Attachment> attachments,
) => [
  liveEventsProvider.overrideWithValue(const Stream<api.ServerEvent>.empty()),
  messageExtrasProvider.overrideWith((ref) {
    final controller = MessageExtrasController(ref);
    controller.applyMessage(
      api.Message(
        id: messageId,
        channelId: 'c',
        authorId: 'bob',
        authorDisplayName: 'Bob',
        seq: 1,
        content: '',
        createdAt: 0,
        editedAt: null,
        attachments: attachments,
      ),
    );
    return controller;
  }),
];

const _photo = api.Attachment(
  id: 'a1',
  filename: 'sunset.png',
  contentType: 'image/png',
  size: 2048,
);

const _file = api.Attachment(
  id: 'a2',
  filename: 'quarterly-report.pdf',
  contentType: 'application/pdf',
  size: 51200,
);

void main() {
  testWidgets('names the reply target and cancels', (tester) async {
    var cancelled = 0;
    await tester.pumpWidget(
      harness(
        SizedBox(
          width: 460,
          child: ReplyBanner(
            message: message(
              id: 'p',
              authorId: 'ada',
              authorDisplayName: 'Ada Lovelace',
              content: 'the original message being replied to',
            ),
            onCancel: () => cancelled++,
          ),
        ),
      ),
    );

    expect(find.textContaining('Replying to Ada Lovelace'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel reply'));
    expect(cancelled, 1);
  });

  testWidgets('names a text-less parent by what it carried', (tester) async {
    await tester.pumpWidget(
      harness(
        SizedBox(
          width: 460,
          child: ReplyBanner(
            message: message(
              id: 'p',
              authorId: 'bob',
              authorDisplayName: 'Bob',
              content: '',
            ),
            onCancel: () {},
          ),
        ),
        overrides: _carrying('p', const [_photo]),
      ),
    );

    expect(find.textContaining('Photo'), findsOneWidget);
  });

  testWidgets('is one rounded, inset chip rather than a sharp full-bleed bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        SizedBox(
          width: 460,
          child: ReplyBanner(
            message: message(id: 'p', content: 'hi'),
            onCancel: () {},
          ),
        ),
      ),
    );

    final tokens = Theme.of(
      tester.element(find.byType(ReplyBanner)),
    ).extension<AppTokens>()!;
    final chip = find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          (widget.decoration as BoxDecoration).color == tokens.surfaceSunken,
    );
    final decoration =
        tester.widget<DecoratedBox>(chip).decoration as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(AppRadii.control));
    // Compact: one caption line plus padding, not the full-height strip this used to be.
    final size = tester.getSize(chip);
    expect(size.height, lessThan(48));
  });

  testWidgets('a text-less reply to a single photo shows its thumbnail, not '
      'the plain reply arrow', (tester) async {
    var fetched = false;
    await tester.pumpWidget(
      harness(
        SizedBox(
          width: 460,
          child: ReplyBanner(
            message: message(
              id: 'p',
              authorId: 'bob',
              authorDisplayName: 'Bob',
              content: '',
            ),
            onCancel: () {},
          ),
        ),
        overrides: [
          ..._carrying('p', const [_photo]),
          attachmentBytesProvider(_photo.id).overrideWith((ref) async {
            fetched = true;
            return Uint8List.fromList(const [1, 2, 3, 4]);
          }),
        ],
      ),
    );
    await tester.pump();

    expect(find.byIcon(AppIcons.reply), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(fetched, isTrue);
  });

  testWidgets(
    'a text-less reply to a single file shows a compact file glyph, never a '
    'blank or oversized line',
    (tester) async {
      await tester.pumpWidget(
        harness(
          SizedBox(
            width: 460,
            child: ReplyBanner(
              message: message(
                id: 'p',
                authorId: 'bob',
                authorDisplayName: 'Bob',
                content: '',
              ),
              onCancel: () {},
            ),
          ),
          overrides: _carrying('p', const [_file]),
        ),
      );

      expect(find.textContaining(_file.filename), findsOneWidget);
      expect(find.byIcon(AppIcons.attachFile), findsOneWidget);
      expect(find.byIcon(AppIcons.reply), findsNothing);
      expect(find.byType(Image), findsNothing);
    },
  );

  testWidgets(
    'a photo reply with auto-download off shows a glyph, never fetching the '
    'image just to stage a reply',
    (tester) async {
      var fetched = false;
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWith(
            (ref) => SharedPreferences.getInstance(),
          ),
          ..._carrying('p', const [_photo]),
          attachmentBytesProvider(_photo.id).overrideWith((ref) async {
            fetched = true;
            return Uint8List.fromList(const [1, 2, 3, 4]);
          }),
        ],
      );
      addTearDown(container.dispose);
      await container
          .read(mediaAutoDownloadControllerProvider.notifier)
          .select(MediaAutoDownload.manual);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: SizedBox(
                width: 460,
                child: ReplyBanner(
                  message: message(
                    id: 'p',
                    authorId: 'bob',
                    authorDisplayName: 'Bob',
                    content: '',
                  ),
                  onCancel: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(AppIcons.image), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(fetched, isFalse);
    },
  );

  testWidgets(
    'a reply naming several attachments keeps the plain reply arrow, since '
    'no single thumbnail could speak for all of them',
    (tester) async {
      await tester.pumpWidget(
        harness(
          SizedBox(
            width: 460,
            child: ReplyBanner(
              message: message(
                id: 'p',
                authorId: 'bob',
                authorDisplayName: 'Bob',
                content: '',
              ),
              onCancel: () {},
            ),
          ),
          overrides: _carrying('p', const [_photo, _file]),
        ),
      );

      expect(find.byIcon(AppIcons.reply), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('2 attachments'), findsOneWidget);
    },
  );

  testWidgets('renders a picture of both cases', (tester) async {
    tester.view.physicalSize = const Size(500, 260);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        Builder(
          builder: (context) {
            final tokens = Theme.of(context).extension<AppTokens>()!;
            return ColoredBox(
              color: tokens.surfaceBase,
              child: RepaintBoundary(
                key: snapshotBoundary,
                child: SizedBox(
                  width: 500,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ReplyBanner(
                        message: message(
                          id: 'p1',
                          authorId: 'ada',
                          authorDisplayName: 'Ada Lovelace',
                          content: 'the original message being replied to',
                        ),
                        onCancel: () {},
                      ),
                      const SizedBox(height: AppSpacing.s16),
                      ReplyBanner(
                        message: message(
                          id: 'p2',
                          authorId: 'bob',
                          authorDisplayName: 'Bob',
                          content: '',
                        ),
                        onCancel: () {},
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        overrides: _carrying('p2', const [_photo]),
      ),
    );
    await tester.pump();
    await writeSnapshot(tester, 'reply-banner');
  });
}
