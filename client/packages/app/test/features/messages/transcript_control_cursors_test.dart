// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every clickable control a message row can hold shows the click cursor
/// inside the transcript's `SelectionArea`, where a plain `Text` would
/// otherwise claim the pointer with the I-beam.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/features/composer/widgets/poll_option_row.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/messages/providers/link_preview.dart';
import 'package:slimm_app/src/features/messages/widgets/author_profile_tap_target.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_chip.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_reveal.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_spoiler.dart';
import 'package:slimm_app/src/features/messages/widgets/ephemeral_row.dart';
import 'package:slimm_app/src/features/messages/widgets/link_preview_card.dart';
import 'package:slimm_app/src/features/messages/widgets/message_buttons.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_parts.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/text_link.dart';
import 'package:slimm_api/api.dart' show LinkPreview;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWith(
          (ref) => SharedPreferences.getInstance(),
        ),
        ...overrides,
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SelectionArea(child: Center(child: child)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _expectClickOver(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(target.first));
  await tester.pump();
  expect(
    RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
    SystemMouseCursors.click,
  );
  await mouse.removePointer();
}

api.EphemeralMessage _ephemeral() => const api.EphemeralMessage(
  id: 'e1',
  channelId: 'c1',
  authorId: 'bot',
  authorDisplayName: 'Helper',
  content: 'only you can see this',
  inReplyToId: 'm1',
  createdAt: 1,
);

void main() {
  testWidgets('AppButton label', (tester) async {
    await _pump(tester, AppButton(label: 'Press me', onPressed: () {}));
    await _expectClickOver(tester, find.text('Press me'));
  });

  testWidgets('FocusableTapTarget content', (tester) async {
    await _pump(
      tester,
      FocusableTapTarget(
        onTap: () {},
        builder: (context, focused, hovered) => const Text('Tap target'),
      ),
    );
    await _expectClickOver(tester, find.text('Tap target'));
  });

  testWidgets('ephemeral footer links', (tester) async {
    await _pump(
      tester,
      EphemeralRow(
        message: _ephemeral(),
        knownUsernames: const {},
        knownRoleNames: const {},
        customEmoji: const {},
        onDismiss: () {},
        onReport: () {},
      ),
    );
    await _expectClickOver(tester, find.text('Dismiss'));
    await _expectClickOver(tester, find.text('Report'));
  });

  testWidgets('bot message buttons', (tester) async {
    await _pump(
      tester,
      const MessageButtons(
        channelId: 'c1',
        messageId: 'm1',
        rows: [
          api.ComponentRow(
            buttons: [
              api.MessageButton(
                label: 'Hit',
                style: api.ComponentButtonStyle.primary,
                customId: 'hit',
              ),
              api.MessageButton(
                label: 'Rules',
                style: api.ComponentButtonStyle.link,
                url: 'https://example.com/rules',
              ),
            ],
          ),
        ],
      ),
    );
    await _expectClickOver(tester, find.text('Hit'));
    await _expectClickOver(tester, find.text('Rules'));
  });

  testWidgets('embed title link', (tester) async {
    await _pump(tester, TextLink(onOpen: () {}, child: const Text('Title')));
    await _expectClickOver(tester, find.text('Title'));
  });

  testWidgets('poll option', (tester) async {
    await _pump(
      tester,
      SizedBox(
        width: 300,
        child: PollOptionRow(
          option: const api.PollOption(position: 0, label: 'Pizza', votes: 1),
          votes: 1,
          totalVotes: 2,
          selected: false,
          leading: false,
          onTap: () {},
        ),
      ),
    );
    await _expectClickOver(tester, find.text('Pizza'));
  });

  testWidgets('edited marker', (tester) async {
    await _pump(tester, EditedMarker(onTap: () {}));
    await _expectClickOver(tester, find.textContaining('edited'));
  });

  testWidgets('attachment chip', (tester) async {
    await _pump(
      tester,
      const AttachmentChip(
        attachment: api.Attachment(
          id: 'f1',
          filename: 'notes.pdf',
          contentType: 'application/pdf',
          size: 10,
        ),
      ),
    );
    await _expectClickOver(tester, find.textContaining('notes.pdf'));
  });

  testWidgets('attachment reveal tile', (tester) async {
    await _pump(
      tester,
      AttachmentRevealTile(
        caption: 'clip.gif',
        onReveal: () {},
        maxEdge: 200,
        icon: AppIcons.play,
      ),
    );
    await _expectClickOver(tester, find.textContaining('clip.gif'));
  });

  testWidgets('attachment spoiler cover', (tester) async {
    await _pump(
      tester,
      AttachmentSpoilerCover(
        filename: 'x.png',
        onReveal: () {},
        child: const SizedBox(width: 200, height: 100),
      ),
    );
    await _expectClickOver(tester, find.textContaining('poiler'));
  });

  testWidgets('link preview card', (tester) async {
    const url = 'https://example.com/a';
    await _pump(
      tester,
      const LinkPreviewCard(url: url),
      overrides: [
        linkPreviewProvider(url).overrideWith(
          (ref) async => const LinkPreview(
            url: url,
            title: 'An article',
            description: 'What it is about.',
            siteName: 'Example',
          ),
        ),
      ],
    );
    await _expectClickOver(tester, find.text('What it is about.'));
  });

  testWidgets('channel mention chip', (tester) async {
    await _pump(
      tester,
      const ChannelMentionChip(channelId: 'c9'),
      overrides: [
        channelByIdProvider('c9').overrideWith(
          (ref) => Stream.value(
            const Channel(
              id: 'c9',
              name: 'general',
              kind: 'text',
              createdAt: 0,
              position: 0,
              cursor: 0,
              lastReadSeq: 0,
              mentionedSeq: 0,
              slowModeSeconds: 0,
              joinMuted: false,
              isPersonalSpace: false,
            ),
          ),
        ),
      ],
    );
    await _expectClickOver(tester, find.text('#general'));
  });

  testWidgets('author name opening the profile', (tester) async {
    await _pump(
      tester,
      const AuthorProfileTapTarget(
        authorId: 'u1',
        semanticLabel: 'Priya',
        child: Text('Priya'),
      ),
      overrides: [
        userProfileProvider('u1').overrideWith(
          (ref) async => const api.UserProfile(
            id: 'u1',
            username: 'priya',
            displayName: 'Priya',
            createdAt: 0,
          ),
        ),
      ],
    );
    await _expectClickOver(tester, find.text('Priya'));
  });
}
