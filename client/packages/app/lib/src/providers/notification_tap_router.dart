// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opens the channel a push notification came from when somebody taps it.
///
/// Reported from real device use, as: tapping a notification "takes me to the
/// channel page but I have no idea where that message came from". It did not
/// take anyone anywhere - nothing in this client listened for a tap at all,
/// so the app simply resumed to whatever route it was last on, which is only
/// the right channel by coincidence.
///
/// The routing decision is [channelRouteForTap], a pure function, so what
/// this does with a tap can be tested without a router, a platform channel or
/// a device - none of which this project can drive for iOS. The provider is
/// the wiring around it and nothing else.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../features/accounts/providers/account_host.dart';
import '../features/accounts/providers/account_providers.dart';
import '../routing/routes.dart';
import 'providers.dart' show storeProvider;
import '../routing/router.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// The route a tap naming [channelId] should land on, or null for a tap
/// carrying nothing usable.
///
/// A thread gets no case of its own: a reply into a thread pushes under the
/// thread's own channel id, and [Routes.channel] renders a thread's transcript
/// exactly as `ChannelScreen` already does for one reached any other way.
///
/// Routed with `openChat`: a notification is about a message, so landing in
/// a voice channel means its chat, not its call. Without it the tap joined
/// the call - mic state and all - for someone who only meant to read.
String? channelRouteForTap(String? channelId) {
  if (channelId == null || channelId.isEmpty) return null;
  return Routes.channel(channelId, openChat: true);
}

/// Opens [channelId] on the account it belongs to, switching to it first.
///
/// [origin] names the account when the tap says so; a push carries only a
/// channel id, so otherwise the account whose local store knows the channel
/// wins, and the one on screen is the fallback.
Future<void> openChannelOnOwner(
  AccountHost host,
  String channelId, {
  String? origin,
}) async {
  final route = channelRouteForTap(channelId);
  if (route == null) return;
  final target =
      (origin == null ? null : host.runtimeFor(origin)) ??
      await _ownerOf(host, channelId) ??
      host.active;
  if (target == null) return;
  final account = target.account;
  if (target != host.active && account != null) {
    await host.switchTo(account.origin);
  }
  target.container.read(routerProvider).go(route);
}

Future<AccountRuntime?> _ownerOf(AccountHost host, String channelId) async {
  final candidates = [
    if (host.active != null) host.active!,
    ...host.accounts.where((r) => r != host.active),
  ];
  for (final runtime in candidates) {
    try {
      final store = await runtime.container.read(storeProvider.future);
      if (await store.channelRow(channelId) != null) return runtime;
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.push,
        "Could not open this account's data to find the channel; trying the next account",
        error,
        stack,
      );
    }
  }
  return null;
}

/// Listens for notification taps and routes to the channel each came from.
///
/// Mounted by watching it from the app root. Two sources feed it and both are
/// needed: [NotificationTapChannel.takeInitial] for the tap that launched a
/// killed app, whose native-side delivery lands before Dart can hear it, and
/// [NotificationTapChannel.taps] for one arriving while the app is running.
///
/// Signed-out is deliberately not special-cased here. The router's own
/// redirect already sends anyone without a session to sign-in from wherever
/// they were pointed, so a second check in this file would be a second
/// authority over the same question.
final notificationTapRouterProvider = Provider<void>((ref) {
  final channel = ref.watch(notificationTapChannelProvider);

  void go(String? channelId) {
    final route = channelRouteForTap(channelId);
    if (route == null) return;
    final host = ref.read(accountHostProvider);
    if (host == null) {
      ref.read(routerProvider).go(route);
      return;
    }
    unawaited(openChannelOnOwner(host, channelId!));
  }

  final subscription = channel.taps.listen(go);
  ref.onDispose(subscription.cancel);

  unawaited(channel.takeInitial().then(go));
});

/// The platform seam, overridable in tests.
final notificationTapChannelProvider = Provider<NotificationTapChannel>((ref) {
  final channel = NotificationTapChannel();
  ref.onDispose(channel.dispose);
  return channel;
});
