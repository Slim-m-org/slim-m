// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reporting a bot's private message. The server kept no copy, so the report
/// carries the text this client showed. See
/// docs/decisions/0037-ephemeral-bot-messages.md.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'safety_actions.dart';

/// The server refuses a longer snapshot.
const int maxEphemeralSnapshotChars = 4000;

/// Everything readable on the card, as text a moderator can read.
String ephemeralSnapshot(api.EphemeralMessage message) {
  final lines = <String>[
    if (message.content.trim().isNotEmpty) message.content.trim(),
    for (final embed in message.embeds) ..._embedLines(embed),
    for (final file in message.attachments) '[file] ${file.filename}',
  ];
  final text = lines.join('\n');
  final runes = text.runes;
  if (runes.length <= maxEphemeralSnapshotChars) return text;
  return String.fromCharCodes(runes.take(maxEphemeralSnapshotChars));
}

Iterable<String> _embedLines(api.Embed embed) => [
  if (embed.authorName != null) embed.authorName!,
  if (embed.title != null) embed.title!,
  if (embed.description != null) embed.description!,
  for (final field in embed.fields) '${field.name}: ${field.value}',
  if (embed.footerText != null) embed.footerText!,
];

Future<void> reportEphemeralMessage(
  BuildContext context,
  api.EphemeralMessage message,
) => fileReport(
  context,
  ProviderScope.containerOf(context, listen: false),
  subject: api.ReportSubject.ephemeralMessage,
  subjectId: message.id,
  subjectLabel: 'this private message',
  channelId: message.channelId,
  authorId: message.authorId,
  snapshot: ephemeralSnapshot(message),
);
