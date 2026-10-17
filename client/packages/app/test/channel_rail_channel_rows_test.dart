// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `ManagedChannelRow` used to compose the manage kebab as a sibling of the
/// channel row rather than inside it, so the row's own hover/press
/// highlight (painted by `AppListRow`'s tinted container) visibly stopped
/// short of the kebab and the row read as two separate pieces.
///
/// These tests pin the fix structurally (the kebab must be a descendant of
/// the row's own `AppListRow`, not a sibling beside it) rather than by
/// pixel, and pin the trap the fix has to avoid: `AppListRow.trailing`
/// already falls back to an unread dot, so handing the kebab to that same
/// slot would have silently dropped the dot on every unread channel.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_channel_rows.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/features/members/widgets/user_avatar.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _tokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

Channel _channel(
  String id,
  String name, {
  String kind = 'text',
  int cursor = 0,
  int lastReadSeq = 0,
}) => Channel(
  id: id,
  name: name,
  kind: kind,
  createdAt: 0,
  position: 0,
  cursor: cursor,
  lastReadSeq: lastReadSeq,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

/// [ChannelCategorySections] and [ManagedChannelRow] read one provider now,
/// [channelNotificationOverridesProvider] (the muted glyph a text row
/// carries), so this needs the same minimal session/api overrides
/// [_voiceHarness] below already carries for the identical reason - a bare
/// scope would construct the real controller against an unconfigured
/// session and a real network client.
Widget _harness(Widget child) => ProviderScope(
  overrides: [
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    apiProvider.overrideWith((ref) {
      final client = api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: ref.watch(sessionProvider),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      ref.onDispose(client.close);
      return client;
    }),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: child),
  ),
);

/// [VoiceChannelRow] renders an [UserAvatar] per participant, which does
/// read providers (a profile lookup, an avatar-bytes cache), so the voice
/// test below needs a real session and API client the way
/// `channel_rail_voice_roster_test.dart` already does for the same widget.
/// [voice] overrides [voiceControllerProvider] directly now that the row
/// watches it itself rather than taking it as a constructor parameter (see
/// the finding about `ChannelCategorySections` rebuilding every row on
/// every voice-room event).
Widget _voiceHarness(Widget child, {required VoiceState voice}) =>
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((_) async => http.Response('', 404)),
          );
          ref.onDispose(client.close);
          return client;
        }),
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(ref, voice),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets(
    'the kebab is a descendant of AppListRow, so the row highlight covers '
    'it rather than stopping short of it',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          ChannelCategorySections(
            channels: [_channel('c1', 'general')],
            categories: const [],
            selectedId: null,
            canManage: true,
            onReorder: (_) {},
          ),
        ),
      );
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(AppListRow),
          matching: find.byIcon(AppIcons.moreVertical),
        ),
        findsOneWidget,
        reason:
            'a kebab composed as a sibling of AppListRow sits outside the '
            'AnimatedContainer that paints its hover/press tint',
      );
    },
  );

  testWidgets(
    'an unread channel keeps its unread dot once it also carries a kebab',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          ChannelCategorySections(
            channels: [_channel('c1', 'general', cursor: 5, lastReadSeq: 2)],
            categories: const [],
            selectedId: null,
            canManage: true,
            onReorder: (_) {},
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(AppListRow.unreadDotKey),
        findsOneWidget,
        reason:
            'AppListRow.trailing already falls back to the unread dot; '
            'routing the kebab through trailingExtra instead of trailing '
            'must leave that fallback untouched',
      );
      expect(
        find.descendant(
          of: find.byType(AppListRow),
          matching: find.byIcon(AppIcons.moreVertical),
        ),
        findsOneWidget,
        reason: 'the kebab must render alongside the dot, not replace it',
      );
    },
  );

  testWidgets(
    'a voice row with a kebab still centres it against the row alone, not '
    'the combined height of the row and its participant strip below',
    (tester) async {
      final channel = _channel('v1', 'General voice', kind: 'voice');
      await tester.pumpWidget(
        _voiceHarness(
          ManagedChannelRow(
            canManage: true,
            reorderable: false,
            channel: channel,
            row: (kebab) => VoiceChannelRow(
              channel: channel,
              selected: false,
              trailingExtra: kebab,
            ),
          ),
          voice: const VoiceState(
            channelId: 'v1',
            state: VoiceSessionState.connected,
            participants: [
              VoiceParticipant(
                identity: 'u-1',
                name: 'Alice',
                isSpeaking: false,
                isMuted: false,
                isLocal: true,
                isScreenSharing: false,
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(AppListRow),
          matching: find.byIcon(AppIcons.moreVertical),
        ),
        findsOneWidget,
        reason:
            'the participant strip is a sibling of AppListRow, not part of '
            'it, so a kebab living inside the row is scoped to the row alone',
      );

      final rowBottom = tester.getBottomLeft(find.byType(AppListRow)).dy;
      final kebabCenter = tester
          .getCenter(find.byIcon(AppIcons.moreVertical))
          .dy;
      expect(
        kebabCenter,
        lessThan(rowBottom),
        reason:
            'the kebab must sit within the row itself, never floating '
            'against the combined row-plus-strip height below it',
      );
      expect(
        find.byType(UserAvatar),
        findsOneWidget,
        reason: 'the participant strip must still render beneath the row',
      );
    },
  );

  testWidgets(
    'a voice channel with unread text shows the same unread dot a text '
    'channel does',
    (tester) async {
      final channel = _channel(
        'v1',
        'General voice',
        kind: 'voice',
        cursor: 5,
        lastReadSeq: 2,
      );
      await tester.pumpWidget(
        _voiceHarness(
          VoiceChannelRow(channel: channel, selected: false),
          voice: const VoiceState(),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(AppListRow.unreadDotKey),
        findsOneWidget,
        reason:
            'a voice channel now has its own transcript and composer '
            '(screens/voice_text_pane.dart), so unread text there must '
            'show the same affordance an unread text channel does',
      );
    },
  );

  testWidgets(
    'a voice channel caught up on text has no unread dot even while a call '
    'is live in it',
    (tester) async {
      final channel = _channel(
        'v1',
        'General voice',
        kind: 'voice',
        cursor: 2,
        lastReadSeq: 2,
      );
      await tester.pumpWidget(
        _voiceHarness(
          VoiceChannelRow(channel: channel, selected: false),
          voice: const VoiceState(
            channelId: 'v1',
            state: VoiceSessionState.connected,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(AppListRow.unreadDotKey),
        findsNothing,
        reason:
            'being in the call already has its own cue (the accented mic '
            'icon), so it must not also light the unread dot the way the '
            'old inCall-based read used to for every member on the call',
      );
    },
  );

  testWidgets('a phone long-press on a channel row opens its context menu', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final channel = _channel('c1', 'general');
    await tester.pumpWidget(
      _harness(
        ManagedChannelRow(
          canManage: true,
          reorderable: false,
          channel: channel,
          row: (kebab) => AppListRow(label: channel.name, trailing: kebab),
        ),
      ),
    );
    await tester.pump();

    await tester.longPress(find.text('general'));
    await tester.pumpAndSettle();

    expect(
      find.text('Mute channel'),
      findsOneWidget,
      reason:
          'a phone reaches this menu by held press and by nothing else, so '
          'a reorderable rail must not take that gesture away',
    );
  });

  testWidgets(
    'the kebab occupies the same rect hidden or revealed, so a hover never '
    'reflows the row (backlog 131)',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          ChannelCategorySections(
            channels: [_channel('c1', 'general')],
            categories: const [],
            selectedId: null,
            canManage: true,
            onReorder: (_) {},
          ),
        ),
      );
      await tester.pump();

      final rowFinder = find.byType(AppListRow);
      final kebabFinder = find.byIcon(AppIcons.moreVertical);
      final rowSizeBefore = tester.getSize(rowFinder);
      final kebabRectBefore = tester.getRect(kebabFinder);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(rowFinder));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(rowFinder),
        rowSizeBefore,
        reason: 'hovering must never resize the row itself',
      );
      expect(
        tester.getRect(kebabFinder),
        kebabRectBefore,
        reason:
            "the kebab's slot is reserved up front; a hover only "
            'animates its opacity, never its geometry',
      );

      await gesture.removePointer();
    },
  );

  testWidgets(
    "hovering a selected row's kebab shows only the row's own selection "
    'tint, not a second, mismatched fill painted by the button itself '
    '(backlog 131)',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      await tester.pumpWidget(
        _harness(
          ChannelCategorySections(
            channels: [_channel('c1', 'general')],
            categories: const [],
            selectedId: 'c1',
            canManage: true,
            onReorder: (_) {},
          ),
        ),
      );
      await tester.pump();

      final kebabFinder = find.byIcon(AppIcons.moreVertical);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(kebabFinder));
      await tester.pumpAndSettle();

      // Scoped to the kebab's own button: a section header's add glyph is an AppIconButton too.
      final buttonFill = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.ancestor(
            of: kebabFinder,
            matching: find.byType(AppIconButton),
          ),
          matching: find.byType(AnimatedContainer),
        ),
      );
      expect(
        (buttonFill.decoration as BoxDecoration).color,
        Colors.transparent,
        reason:
            "the kebab must not paint its own surfaceRaised fill on top of "
            "the row's accentSoft selection tint",
      );

      final rowTint = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byType(AppListRow),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      expect(
        (rowTint.decoration as BoxDecoration).color,
        AppTokens.light.accentSoft,
        reason: 'the row keeps its single selection tint under the kebab',
      );

      await gesture.removePointer();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    "hovering an unselected row's kebab keeps the row's hover fill under it "
    'and shows no second fill (backlog 131)',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      await tester.pumpWidget(
        _harness(
          ChannelCategorySections(
            channels: [_channel('c1', 'general')],
            categories: const [],
            selectedId: null,
            canManage: true,
            onReorder: (_) {},
          ),
        ),
      );
      await tester.pump();

      final kebabFinder = find.byIcon(AppIcons.moreVertical);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(kebabFinder));
      await tester.pumpAndSettle();

      final hoverFill = find
          .descendant(
            of: find.byType(AppListRow),
            matching: find.byType(AnimatedContainer),
          )
          .at(1);
      expect(
        (tester.widget<AnimatedContainer>(hoverFill).decoration
                as BoxDecoration)
            .color,
        AppTokens.light.surfaceRaised,
      );
      final fill = tester.getRect(hoverFill);
      final kebab = tester.getRect(kebabFinder);
      expect(fill.inflate(0.5).expandToInclude(kebab), fill.inflate(0.5));
      await gesture.removePointer();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
