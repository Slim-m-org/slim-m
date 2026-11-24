// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Wires [DirectPlayController] to the room, the call's shares, this device's
/// secrets and the real player. See `direct_play_controller.dart`.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../providers/providers.dart';
import 'direct_play_controller.dart';
import 'direct_player.dart';
import 'jellyfin_credential_store.dart';
import 'jellyfin_direct_client.dart';
import 'media_kit_direct_player.dart';
import 'share_watch.dart';
import 'voice_flags.dart';
import 'watch_room.dart';

const String _enabledKey = 'watch.direct_play.enabled';

final directPlayerFactoryProvider = Provider<DirectPlayer Function()>(
  (ref) => MediaKitDirectPlayer.new,
);

final directPlayHttpProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Whether this device can play the original file untranscoded; a browser usually cannot.
final directPlaySupportedProvider = Provider<bool>((ref) => !kIsWeb);

/// Builds the channel's controller and feeds it the room and the call's shares.
final directPlayControllerProvider = Provider.autoDispose
    .family<DirectPlayController, String>((ref, channelId) {
      final prefs = ref.read(preferencesProvider).valueOrNull;
      final credentials = JellyfinCredentialStore(ref.read(keyStoreProvider));
      final selfId = ref.read(sessionProvider).tokens?.userId ?? '';
      final shares = ref.read(shareWatchProvider.notifier);
      final deviceId = 'slim-m-${Random.secure().nextInt(1 << 31)}';
      final controller = DirectPlayController(
        DirectPlayEnvironment(
          slimm: ref.watch(apiProvider),
          selfId: selfId,
          clock: ref.watch(watchClockProvider),
          client: JellyfinDirectClient(
            ref.watch(directPlayHttpProvider),
            deviceId: deviceId,
          ),
          makePlayer: ref.watch(directPlayerFactoryProvider),
          loadCredential: (url) => credentials.load(selfId, url),
          saveCredential: (url, session) =>
              credentials.save(selfId, url, session),
          forgetCredential: (url) => credentials.forget(selfId, url),
          saveEnabled: (enabled) async {
            final store = await ref.read(preferencesProvider.future);
            await store.setBool(_enabledKey, enabled);
          },
          holdShare: shares.hold,
          releaseShare: shares.watch,
          directPlaySupported: ref.watch(directPlaySupportedProvider),
        ),
        channelId,
        enabled: prefs?.getBool(_enabledKey) ?? false,
      );
      ref.listen<AsyncValue<WatchRoom?>>(
        watchRoomProvider(channelId),
        (_, next) => unawaited(controller.onRoom(next.valueOrNull)),
        fireImmediately: true,
      );
      ref.listen<Set<String>>(shareWatchProvider.select((s) => s.held), (
        _,
        held,
      ) {
        final bot = controller.heldBot;
        if (bot == null || held.contains(bot)) return;
        final callEnded = ref.read(voiceChannelAtOnce) != channelId;
        unawaited(
          callEnded ? controller.stopForCallEnd() : controller.disable(),
        );
      });
      ref.onDispose(controller.dispose);
      return controller;
    });

/// The channel's direct-play state; the work happens in [DirectPlayController].
class DirectPlay extends AutoDisposeFamilyNotifier<DirectPlayState, String> {
  @override
  DirectPlayState build(String channelId) {
    final c = ref.watch(directPlayControllerProvider(channelId));
    c.onChange((next) => state = next);
    return c.current;
  }

  DirectPlayController get controller =>
      ref.read(directPlayControllerProvider(arg));
}

final directPlayProvider = NotifierProvider.autoDispose
    .family<DirectPlay, DirectPlayState, String>(DirectPlay.new);
