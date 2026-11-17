// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A fetched message as the transcript draws one, for messages held in memory
/// rather than written to the local store.
library;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart' show Message, ForwardedMessage;

/// [m] as a delivered local row.
Message localMessageOf(api.Message m) => Message(
  id: m.id,
  channelId: m.channelId,
  authorId: m.authorId,
  authorDisplayName: m.authorDisplayName,
  seq: m.seq,
  content: m.content,
  createdAt: m.createdAt,
  editedAt: m.editedAt,
  replyToId: m.replyToId,
  forwarded: m.forwarded == null
      ? null
      : ForwardedMessage(
          messageId: m.forwarded!.messageId,
          channelId: m.forwarded!.channelId,
          authorId: m.forwarded!.authorId,
          authorDisplayName: m.forwarded!.authorDisplayName,
          authorAvatarUpdatedAt: m.forwarded!.authorAvatarUpdatedAt,
          createdAt: m.forwarded!.createdAt,
          content: m.forwarded!.content,
          removed: m.forwarded!.removed,
        ),
  linkPreviewsRemoved: m.linkPreviewsRemoved,
  pending: false,
  failed: false,
);
