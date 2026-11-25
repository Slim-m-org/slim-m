// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas kind through the glyph and the call, forward and notification
/// rules: each site asks the channel what it hosts, never what its kind string is.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart'
    show channelDefaultOf;
import 'package:slimm_app/src/features/channels/widgets/channel_kind_icon.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_title_glyph.dart';
import 'package:slimm_app/src/features/messages/providers/forward_targets.dart';
import 'package:slimm_app/src/features/voice/providers/call_restore.dart';
import 'package:slimm_app/src/features/voice/providers/member_voice_channel.dart';
import 'package:slimm_app/src/features/voice/widgets/move_participant_popover.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

api.Channel _channel(
  String id,
  String kind, {
  bool? canvas,
  bool? voice,
  bool restricted = false,
}) => api.Channel(
  id: id,
  name: id,
  kind: kind,
  createdAt: 0,
  permissions: Perm.moveMembers,
  restricted: restricted,
  canvasEnabled: canvas,
  voiceEnabled: voice,
);

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  group('glyph', () {
    for (final (kind, icon) in [
      (ChannelGlyphKind.text, AppIcons.hash),
      (ChannelGlyphKind.voice, AppIcons.voice),
      (ChannelGlyphKind.canvas, AppIcons.canvas),
    ]) {
      testWidgets('${kind.name} draws its own icon', (tester) async {
        await _pump(
          tester,
          ChannelKindIcon(glyph: kind, restricted: false, color: Colors.black),
        );
        expect(find.byIcon(icon), findsOneWidget);
      });
    }

    testWidgets('a restricted canvas channel says so', (tester) async {
      await _pump(
        tester,
        const ChannelKindIcon(
          glyph: ChannelGlyphKind.canvas,
          restricted: true,
          color: Colors.black,
        ),
      );
      expect(
        find.bySemanticsLabel(ChannelKindIcon.canvasLabel),
        findsOneWidget,
      );
      expect(find.byIcon(AppIcons.canvas), findsOneWidget);
    });

    testWidgets('the header glyph of a canvas channel is the canvas icon', (
      tester,
    ) async {
      await _pump(
        tester,
        const ChannelTitleGlyph(
          name: 'designs',
          glyph: ChannelGlyphKind.canvas,
          restricted: false,
          isDm: false,
          isPersonalSpace: false,
          dmParticipantId: null,
        ),
      );
      expect(find.byIcon(AppIcons.canvas), findsOneWidget);
    });

    test('an unknown kind reads as text', () {
      expect(ChannelGlyphKind.of('hologram'), ChannelGlyphKind.text);
      expect(ChannelGlyphKind.of('canvas'), ChannelGlyphKind.canvas);
    });
  });

  test('move targets include a canvas channel only when it hosts a call', () {
    final all = [
      _channel('v', 'voice'),
      _channel('c-call', 'canvas', canvas: true, voice: true),
      _channel('c-quiet', 'canvas', canvas: true, voice: false),
      _channel('t', 'text'),
    ];
    expect(moveTargets(all, 'x').map((c) => c.id), ['v', 'c-call']);
  });

  test('a canvas channel opens its chat from a forward or a share', () {
    const target = ForwardTarget(
      channelId: 'c',
      label: 'c',
      isDm: false,
      kind: 'canvas',
    );
    expect(target.opensChat, isTrue);
    expect(
      const ForwardTarget(channelId: 't', label: 't', isDm: false).opensChat,
      isFalse,
    );
  });

  test('a canvas channel notifies like a voice chat: mentions by default', () {
    Channel row(String kind) => Channel(
      id: 'c',
      name: 'c',
      kind: kind,
      createdAt: 0,
      position: 0,
      cursor: 0,
      lastReadSeq: 0,
      mentionedSeq: 0,
      slowModeSeconds: 0,
      joinMuted: false,
      isPersonalSpace: false,
    );
    expect(
      channelDefaultOf(row('canvas')),
      api.NotificationPreference.mentions,
    );
    expect(channelDefaultOf(row('voice')), api.NotificationPreference.mentions);
    expect(channelDefaultOf(row('text')), isNull);
  });

  group('call lists follow what hosts a call', () {
    late SlimmDatabase db;
    late ProviderContainer container;

    setUp(() async {
      db = SlimmDatabase(NativeDatabase.memory());
      await MessageStore(db).upsertChannels(const [
        api.Channel(id: 'v', name: 'v', kind: 'voice', createdAt: 0),
        api.Channel(
          id: 'c-call',
          name: 'c-call',
          kind: 'canvas',
          createdAt: 1,
          canvasEnabled: true,
          voiceEnabled: true,
        ),
        api.Channel(
          id: 'c-quiet',
          name: 'c-quiet',
          kind: 'canvas',
          createdAt: 2,
          canvasEnabled: true,
          voiceEnabled: false,
        ),
        api.Channel(id: 't', name: 't', kind: 'text', createdAt: 3),
      ]);
      container = ProviderContainer(
        overrides: [
          storeProvider.overrideWith((ref) async => MessageStore(db)),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test(
      'the member call chip lists a canvas channel that hosts a call',
      () async {
        container.listen(visibleVoiceChannelsProvider, (_, _) {});
        await container.read(storeProvider.future);
        await pumpEventQueue();
        final ids = container
            .read(visibleVoiceChannelsProvider)
            .requireValue
            .map((c) => c.id)
            .toSet();
        expect(ids, {'v', 'c-call'});
      },
    );

    test(
      'a restored call can rejoin a canvas channel that hosts one',
      () async {
        final restorable = container.read(restorableChannelProvider);
        expect(await restorable('c-call'), 'c-call');
        expect(await restorable('c-quiet'), isNull);
        expect(await restorable('t'), isNull);
      },
    );
  });
}
