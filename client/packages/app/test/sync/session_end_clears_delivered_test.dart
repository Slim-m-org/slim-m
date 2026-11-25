// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ending a session removes the push previews its account left on iOS.
library;

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/app_badge_sync.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/sync/providers/sync_session_end.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

import '../support/fake_voice.dart';

final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'sign-out asks iOS to drop the delivered previews of its channels',
    () async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('top.npcserver.slimm/app_badge');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MessageStore(db);
      await store.upsertChannels([
        const api.Channel(id: 'c-1', name: 'one', kind: 'text', createdAt: 0),
        const api.Channel(id: 'c-2', name: 'two', kind: 'text', createdAt: 0),
      ]);
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          voiceControllerProvider.overrideWith(
            (ref) => FakeVoiceController(ref),
          ),
          storeProvider.overrideWith((ref) async => store),
          appBadgeChannelProvider.overrideWithValue(
            AppBadgeChannel(isIOS: true),
          ),
        ],
      );
      addTearDown(container.dispose);

      await clearSessionState(container.read(_refProvider));

      final clear = calls.singleWhere((c) => c.method == 'clearDelivered');
      final args = clear.arguments as Map;
      expect((args['channelIds'] as List).toSet(), {'c-1', 'c-2'});
      expect(args['all'], isTrue);
    },
  );
}
