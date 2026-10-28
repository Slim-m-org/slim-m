// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a desktop message notification says.
library;

import 'package:slimm_api/api.dart' as api;

import '../../features/messages/widgets/reply_target_summary.dart'
    show previewLine;

/// Long enough for a sentence or two; the OS truncates further on its own.
const desktopNotificationMaxRunes = 200;

/// The title and body for [message]. With [showText] off, or no author to
/// name, the title stays the app's and the body says only who wrote.
({String? title, String body}) desktopNotificationText(
  api.Message message, {
  required bool showText,
  required bool isDm,
  String? channelName,
}) {
  final author = message.authorDisplayName;
  final named = author != null && author.isNotEmpty;
  if (!showText || !named) {
    return (
      title: null,
      body: named ? 'New message from $author' : 'New message',
    );
  }
  final where = isDm || channelName == null || channelName.isEmpty
      ? ''
      : ' in #$channelName';
  return (
    title: '$author$where',
    body: _cut(previewLine(message.content, message.attachments)),
  );
}

String _cut(String text) {
  final runes = text.runes.toList(growable: false);
  if (runes.length <= desktopNotificationMaxRunes) return text;
  return '${String.fromCharCodes(runes.take(desktopNotificationMaxRunes))}…';
}
