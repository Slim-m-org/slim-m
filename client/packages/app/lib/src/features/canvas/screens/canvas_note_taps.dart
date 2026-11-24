// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a tap on a note's rendered text means: ticking a task box or following a link.
///
/// The note is laid out again with the painter's own function, so a tap lands on what was drawn.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../external_link.dart';
import '../../../message_link.dart';
import '../../../providers/providers.dart';
import '../../../providers/toasts.dart';
import '../../../routing/routes.dart';
import '../../channels/widgets/channel_rail.dart' show selectedChannelId;
import '../../messages/widgets/message_jump.dart' show jumpToMessage;
import '../widgets/canvas_note_spans.dart' show noteChannelLinkPrefix;

sealed class NoteTap {
  const NoteTap();
}

/// A task box was hit: [line] is its source line in the note's text.
class NoteCheckTap extends NoteTap {
  const NoteCheckTap(this.objectId, this.line);

  final String objectId;
  final int line;
}

class NoteLinkTap extends NoteTap {
  const NoteLinkTap(this.url);

  final String url;
}

/// How far past a box or a link a finger or a pointer still counts as on it, in world units.
const double _tapSlop = 4;

/// What the note under [world] has at that point, or null when it is plain text or no note is there.
NoteTap? noteTapAt(
  CanvasDocument document,
  Offset world,
  NoteSpanBuilder spans, {
  required bool canToggle,
}) {
  final id = hitTestTopmost(document, world);
  final bounds = id == null ? null : document.objectBounds(id);
  final text = id == null ? null : document.noteTextOf(id);
  if (id == null || bounds == null || text == null || text.isEmpty) return null;
  final style = document.noteStyleOf(id) ?? const CanvasNoteStyle();
  final fontSize = noteTextSizeOf(noteFontSizeFor(bounds.w, bounds.h), style);
  final painter = layoutNoteText(
    spans(
      text,
      TextStyle(
        fontFamily: AppFonts.sans,
        fontSize: fontSize,
        height: noteLineHeight,
      ),
    ),
    fontSize: fontSize,
    width: bounds.w - noteWorldPad * 2,
    maxLines: noteMaxLines(
      bounds.h,
      fontSize * noteLineHeight,
      pad: noteWorldPad,
    ),
  );
  try {
    final local =
        world - Offset(bounds.x + noteWorldPad, bounds.y + noteWorldPad);
    if (canToggle) {
      for (final check in noteChecksOf(painter)) {
        final hit = check.rect.inflate(_tapSlop);
        if (hit.contains(local)) return NoteCheckTap(id, check.line);
      }
    }
    final url = noteLinkAt(painter, local);
    return url == null ? null : NoteLinkTap(url);
  } finally {
    painter.dispose();
  }
}

/// Opens a note's link: a web address outside the app, a message or a channel inside it.
void openNoteLink(BuildContext context, WidgetRef ref, String url) {
  if (url.startsWith(noteChannelLinkPrefix)) {
    final channelId = url.substring(noteChannelLinkPrefix.length);
    GoRouter.of(context).go(Routes.channel(channelId, openChat: true));
    return;
  }
  final message = parseMessageLink(url);
  if (message == null) {
    openExternalHttpUrl(url);
    return;
  }
  if (!messageLinkIsHere(message, ref.read(serverUrlProvider))) {
    ref
        .read(toastsProvider.notifier)
        .show('That link is for a different server.');
    return;
  }
  jumpToMessage(
    GoRouter.of(context),
    ref.read,
    currentChannelId: selectedChannelId(context),
    channelId: message.channelId,
    messageId: message.messageId,
  );
}
