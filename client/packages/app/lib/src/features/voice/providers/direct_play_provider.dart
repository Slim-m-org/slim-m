// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Wires [DirectPlayController] to the room, the call's shares, this device's
/// secrets and the real player. See `direct_play_controller.dart`.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_platform/platform.dart' show KeyStore;

import '../../../providers/providers.dart';
import 'direct_play_controller.dart';
import 'direct_player.dart';
import 'jellyfin_direct_client.dart';
import 'media_kit_direct_player.dart';
import 'share_watch.dart';
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

String _credentialHandle(String baseUrl) =>
    'jellyfin_direct:${Uri.encodeComponent(baseUrl)}';

Future<JellyfinSession?> _loadCredential(KeyStore keys, String baseUrl) async {
  final stored = await keys.read(_credentialHandle(baseUrl));
  final at = stored?.indexOf('|') ?? -1;
  if (stored == null || at < 1) return null;
  return JellyfinSession(
    token: stored.substring(0, at),
    userId: stored.substring(at + 1),
  );
}

final directPlayProvider = StateNotifierProvider.autoDispose
    .family<DirectPlayController, DirectPlayState, String>((ref, channelId) {
      final prefs = ref.read(preferencesProvider).valueOrNull;
      final keys = ref.read(keyStoreProvider);
      final shares = ref.read(shareWatchProvider.notifier);
      final deviceId = 'slim-m-${Random.secure().nextInt(1 << 31)}';
      final controller = DirectPlayController(
        DirectPlayEnvironment(
          slimm: ref.watch(apiProvider),
          selfId: ref.read(sessionProvider).tokens?.userId ?? '',
          clock: ref.watch(watchClockProvider),
          client: JellyfinDirectClient(
            ref.watch(directPlayHttpProvider),
            deviceId: deviceId,
          ),
          makePlayer: ref.watch(directPlayerFactoryProvider),
          loadCredential: (url) => _loadCredential(keys, url),
          saveCredential: (url, session) => keys
              .put(_credentialHandle(url), '${session.token}|${session.userId}')
              .then((_) {}),
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
        if (bot != null && !held.contains(bot)) {
          unawaited(controller.disable());
        }
      });
      return controller;
    });
