// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What is known about one message beyond its text.
library;

import 'package:slimm_api/api.dart' as api;

/// One message's reactions, attachments, poll, and thread reply summary,
/// however much of each is known so far.
class MessageExtras {
  const MessageExtras({
    this.reactions = const [],
    this.attachments = const [],
    this.codeRuns = const [],
    this.poll,
    this.appSurface,
    this.call,
    this.embeds = const [],
    this.webhookUsername,
    this.viaModule,
    this.components = const [],
    this.threadChannelId,
    this.threadReplyCount,
    this.threadLastReplyAt,
    this.threadUnreadCount,
    this.mentionsMe = false,
    this.linkPreviewsRemoved = false,
  });

  final List<api.ReactionSummary> reactions;
  final List<api.Attachment> attachments;

  /// A bot can replace or clear them by editing, so they follow [components]'
  /// rule, through a `message.embeds` frame.
  final List<api.Embed> embeds;

  /// A webhook post's own username label; fixed once the message exists.
  final String? webhookUsername;

  /// The module that posted the message; fixed once it exists.
  final api.ViaModule? viaModule;

  /// A bot's buttons. A bot can replace or clear them, so a REST fetch and a
  /// `message.components` frame both replace the list, where a bare live
  /// create or edit frame only ever adds.
  final List<api.ComponentRow> components;

  /// The shared result of each fenced code block run in this message, one
  /// entry per block, ordered by block index. Follows [reactions]' merge
  /// rule: a REST fetch replaces the list, a bare live frame cannot clobber
  /// it, and a `code_run.changed` broadcast replaces the one block's entry.
  final List<api.CodeRun> codeRuns;
  final api.Poll? poll;

  /// The app this message launches, or null when it launches none. Fixed once
  /// the message exists, like [poll]; its live surface state rides [codeRuns]
  /// at block 0.
  final api.AppSurface? appSurface;

  /// The call this message records, or null on an ordinary message. Fixed
  /// once the message exists, like [appSurface]: a call reaches a terminal
  /// state exactly once and nothing edits it afterwards.
  final api.CallRecord? call;

  /// The thread opened from this message, or null if none is known yet -
  /// same four fields, same merge rule, as [api.Message] carries them.
  final String? threadChannelId;
  final int? threadReplyCount;
  final int? threadLastReplyAt;

  /// How many of the thread's live messages this viewer has not yet read,
  /// or null exactly when [threadChannelId] is null. Only ever set from a
  /// REST fetch: a live `ThreadUpdated` frame carries no per-viewer answer
  /// (see [_applyThreadUpdated]), so this is left as whatever the last
  /// fetch established until the next one corrects it.
  final int? threadUnreadCount;

  /// This viewer is mentioned, including by a reply that pinged them. Per
  /// viewer, so only a REST fetch can clear it.
  final bool mentionsMe;

  /// The message's link-preview cards were removed. One way: a fetch or a
  /// `message.link_previews_removed` frame sets it, and nothing clears it.
  final bool linkPreviewsRemoved;

  MessageExtras copyWith({
    List<api.ReactionSummary>? reactions,
    List<api.Attachment>? attachments,
    List<api.CodeRun>? codeRuns,
    api.Poll? poll,
    api.AppSurface? appSurface,
    api.CallRecord? call,
    List<api.Embed>? embeds,
    List<api.ComponentRow>? components,
    bool? linkPreviewsRemoved,
    String? threadChannelId,
    int? threadReplyCount,
    int? threadLastReplyAt,
  }) => MessageExtras(
    reactions: reactions ?? this.reactions,
    attachments: attachments ?? this.attachments,
    codeRuns: codeRuns ?? this.codeRuns,
    poll: poll ?? this.poll,
    appSurface: appSurface ?? this.appSurface,
    call: call ?? this.call,
    embeds: embeds ?? this.embeds,
    webhookUsername: webhookUsername,
    viaModule: viaModule,
    components: components ?? this.components,
    threadChannelId: threadChannelId ?? this.threadChannelId,
    threadReplyCount: threadReplyCount ?? this.threadReplyCount,
    threadLastReplyAt: threadLastReplyAt ?? this.threadLastReplyAt,
    threadUnreadCount: threadUnreadCount,
    mentionsMe: mentionsMe,
    linkPreviewsRemoved: linkPreviewsRemoved ?? this.linkPreviewsRemoved,
  );

  static const empty = MessageExtras();
}
