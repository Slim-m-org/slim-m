// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Group DMs (decision 0095): a DM channel of 3 to 8 people.
///
/// The channel is an ordinary DM row in the local store, so messages, calls
/// and sync need nothing here. What lives here is the roster: the default
/// name, the four requests, and the live roster a members sheet reads.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../ids.dart';
import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import 'dms.dart';

/// Most people a group holds, the creator included.
const int groupDmMaxPeople = 8;

/// Fewest people a new group starts with.
const int groupDmMinPeople = 3;

/// "A and B", "A, B and C", then "A, B and 3 others", from the other
/// participants' names. Never stored: names change, and nicknames are per
/// viewer.
String defaultGroupName(List<String> otherNames) {
  final names = [
    for (final n in otherNames)
      if (n.isNotEmpty) n,
  ];
  return switch (names.length) {
    0 => 'Group',
    1 => names[0],
    2 => '${names[0]} and ${names[1]}',
    3 => '${names[0]}, ${names[1]} and ${names[2]}',
    _ => '${names[0]}, ${names[1]} and ${names.length - 2} others',
  };
}

/// The local channel row for a group conversation.
api.Channel channelFromGroupDm(
  api.DmConversation dm, {
  required String? selfId,
}) {
  final group = dm.group!;
  final others = [
    for (final m in group.members)
      if (m.id != selfId) m.displayName,
  ];
  return api.Channel(
    id: dm.channelId,
    name: group.name ?? defaultGroupName(others),
    kind: dmChannelKind,
    createdAt: dm.createdAt,
    dmMemberIds: [for (final m in group.members) m.id],
  );
}

/// What a group sentence says about a refusal, naming the block instead of
/// the generic "not allowed" so the person adding knows what to change.
String describeGroupDmFailure(String whatFailed, api.ApiException e) =>
    switch (e) {
      api.ForbiddenException() =>
        'Could not $whatFailed: a block between two of these people stops '
            'them sharing a group.',
      _ => e.message,
    };

Future<void> _store(
  ProviderContainer container,
  api.DmConversation conversation,
) async {
  final selfId = container.read(apiProvider).session.tokens?.userId;
  final store = await container.read(storeProvider.future);
  await store.upsertChannels([
    channelFromGroupDm(conversation, selfId: selfId),
  ]);
}

/// Starts a group with [userIds] (2 to 7 others) and returns its channel id.
Future<String> createGroupDm(
  ProviderContainer container,
  List<String> userIds, {
  String? name,
}) async {
  final conversation = await container
      .read(apiProvider)
      .createGroupDirectMessage(userIds, id: newChannelId(), name: name);
  await _store(container, conversation);
  return conversation.channelId;
}

Future<void> addToGroupDm(
  ProviderContainer container,
  String channelId,
  String userId,
) async {
  final conversation = await container
      .read(apiProvider)
      .addGroupDirectMessageMember(channelId, userId);
  await _store(container, conversation);
}

/// A blank [name] goes back to the default.
Future<void> renameGroupDm(
  ProviderContainer container,
  String channelId,
  String name,
) async {
  final conversation = await container
      .read(apiProvider)
      .renameGroupDirectMessage(channelId, name.trim().isEmpty ? null : name);
  await _store(container, conversation);
}

/// Leaves, then drops the local row so the rail does not wait for a refresh.
Future<void> leaveGroupDm(ProviderContainer container, String channelId) async {
  await container.read(apiProvider).leaveGroupDirectMessage(channelId);
  final store = await container.read(storeProvider.future);
  await store.removeChannel(channelId);
}

/// The group as the server lists it now, for a members sheet. Null once the
/// caller is no longer in it. Re-read when the roster or name changes.
final groupDmProvider = FutureProvider.autoDispose
    .family<api.DmConversation?, String>((ref, channelId) async {
      final sub = ref.read(liveEventsProvider).listen((event) {
        if (event is api.DmChanged && event.channelId == channelId) {
          ref.invalidateSelf();
        }
      });
      ref.onDispose(sub.cancel);
      final all = await ref.read(apiProvider).listDirectMessages();
      for (final dm in all) {
        if (dm.channelId == channelId && dm.isGroup) return dm;
      }
      return null;
    });
