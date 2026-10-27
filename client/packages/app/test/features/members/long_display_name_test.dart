// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A display name at the 64 character limit ellipsizes on every narrow
/// surface instead of overflowing, at phone and desktop width.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/widgets/canvas_participants_sheet.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_voice_participants.dart';
import 'package:slimm_app/src/features/members/providers/bot_ui_uses.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_items.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/features/voice/providers/call_recap.dart';
import 'package:slimm_app/src/features/voice/widgets/call_recap_card.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane_rows.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/presence_controller.dart';
import 'package:slimm_app/src/features/members/providers/user_notes.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';
import '../voice/voice_controller_harness.dart';
import '../../support/call_header_fixture.dart' show FakePresence;
import '../messages/message_row_harness.dart' as rows;

const _spaced =
    'Bartholomew Featherstonehaugh Cholmondeley Wolfeschlegelstein Z';
const _unbroken =
    'WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW';
const _names = [_spaced, _unbroken];

Widget _app(Widget child, {double width = 260, List<Override>? overrides}) =>
    ProviderScope(
      overrides: [
        liveEventsProvider.overrideWithValue(
          const Stream<api.ServerEvent>.empty(),
        ),
        ...?overrides,
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

/// Every paragraph showing [name] is single-line ellipsized, and nothing threw.
void _expectEllipsized(WidgetTester tester, String name, {int lines = 1}) {
  expect(tester.takeException(), isNull);
  final paragraphs = find
      .byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().contains(name),
      )
      .evaluate()
      .map((e) => e.renderObject! as RenderParagraph)
      .toList();
  expect(paragraphs, isNotEmpty, reason: 'name not drawn');
  for (final p in paragraphs) {
    expect(p.overflow, TextOverflow.ellipsis);
    expect(p.maxLines, lines);
    if (lines == 1) expect(p.didExceedMaxLines, isTrue);
  }
}

void main() {
  setUpAll(loadRealFonts);

  for (final name in _names) {
    for (final width in [240.0, 390.0]) {
      testWidgets('member row at ${width}px: $name', (tester) async {
        final profile = api.UserProfile(
          id: 'u1',
          username: 'bob',
          displayName: name,
          createdAt: 0,
          roleIds: const [],
          roles: const [],
        );
        await tester.pumpWidget(
          _app(MemberRow(profile: profile, isSelf: false), width: width),
        );
        _expectEllipsized(tester, name);
      });
    }

    for (final width in [kCallTileMinWidth, 320.0]) {
      testWidgets('call tile at ${width}px: $name', (tester) async {
        await tester.pumpWidget(
          _app(
            CallParticipantTile(
              participant: VoiceParticipant(
                identity: 'u1',
                name: name,
                isSpeaking: false,
                isMuted: false,
                isLocal: false,
                isScreenSharing: false,
              ),
              width: width,
            ),
            width: width,
          ),
        );
        _expectEllipsized(tester, name);
      });
    }

    testWidgets('message author header: $name', (tester) async {
      await tester.pumpWidget(
        _app(
          MessageRow(
            message: rows.message(authorDisplayName: name),
            grouped: false,
            showNewDivider: false,
            knownUsernames: const {},
            actions: rows.noActions,
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
          ),
          width: 360,
        ),
      );
      _expectEllipsized(tester, name);
    });

    testWidgets('call recap participant: $name', (tester) async {
      final at = DateTime(2026);
      await tester.pumpWidget(
        _app(
          CallRecapCard(
            recap: CallRecap(
              channelId: 'v1',
              startedAt: at,
              endedAt: at.add(const Duration(minutes: 5)),
              others: [
                CallParticipantActivity(
                  identity: 'u1',
                  name: name,
                  joinedAt: at,
                ),
              ],
              sharedScreen: false,
              usedCamera: false,
            ),
          ),
        ),
      );
      _expectEllipsized(tester, name);
    });

    testWidgets('mention autocomplete row: $name', (tester) async {
      await tester.pumpWidget(
        _app(
          ComposerAutocomplete(
            suggestions: [
              AutocompleteSuggestion(
                insert: '@bob ',
                label: name,
                detail: '@bob',
              ),
            ],
            selected: 0,
            onPick: (_) {},
            onHover: (_) {},
          ),
        ),
      );
      _expectEllipsized(tester, name);
    });

    testWidgets('rail voice participant: $name', (tester) async {
      await tester.pumpWidget(
        _app(
          RailParticipantList(
            channelId: 'v1',
            participants: [
              VoiceParticipant(
                identity: 'u1',
                name: name,
                isSpeaking: false,
                isMuted: false,
                isLocal: false,
                isScreenSharing: false,
              ),
            ],
          ),
        ),
      );
      _expectEllipsized(tester, name);
    });
  }
  testWidgets('a 32 character mention chip ellipsizes in a narrow message', (
    tester,
  ) async {
    const username = 'wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww';
    await tester.pumpWidget(
      _app(
        const MessageBody(
          content: 'hi @$username there',
          knownUsernames: {username},
        ),
        width: 120,
      ),
    );
    _expectEllipsized(tester, '@$username');
  });

  for (final name in _names) {
    for (final width in [320.0, 1100.0]) {
      testWidgets('member card at ${width}px: $name', (tester) async {
        final profile = api.UserProfile(
          id: 'user-maya',
          username: 'maya',
          displayName: name,
          createdAt: 1788000000000,
          roles: const ['member'],
          roleIds: const ['role-member'],
        );
        await tester.pumpWidget(
          _app(
            SingleChildScrollView(
              child: MemberProfileBody(
                profile: profile,
                compact: width < 600,
                onDone: () {},
              ),
            ),
            width: width < 600 ? width : 360,
            overrides: [
              presenceControllerProvider.overrideWith(
                (ref) =>
                    FakePresence(ref, {profile.id: api.PresenceState.online}),
              ),
              membersProvider.overrideWith((ref) async => [profile]),
              rolesProvider.overrideWith((ref) async => const <api.Role>[]),
              userNoteProvider.overrideWith(
                (ref, id) async =>
                    const api.UserNote(body: null, updatedAt: null),
              ),
            ],
          ),
        );
        await tester.pump();
        _expectEllipsized(tester, name, lines: 2);
      });
    }
  }
  for (final name in _names) {
    testWidgets('canvas participant row: $name', (tester) async {
      await tester.pumpWidget(
        _app(
          CanvasParticipantRow(
            participant: VoiceParticipant(
              identity: 'u1',
              name: name,
              isSpeaking: false,
              isMuted: true,
              isLocal: false,
              isScreenSharing: false,
            ),
          ),
          width: 320,
          overrides: [
            keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
            channelBotUiProvider.overrideWith((ref, _) async => const []),
            voiceControllerProvider.overrideWith(
              (ref) => VoiceController(ref, session: FakeSession()),
            ),
          ],
        ),
      );
      _expectEllipsized(tester, name);
    });
  }
}
