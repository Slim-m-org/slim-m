// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The event WebSocket: typed frames and the connection that carries them.
library;

import 'dart:convert';

import 'client.dart';
import 'models.dart';
import 'events_tallies.dart';
import 'logging/app_log.dart';
import 'events_parse.dart';
import 'events_parse_canvas.dart';

export 'events_connection.dart' show EventConnection, EventConnectionRefused;

// ServerEvent is sealed, so its subclasses must stay in this library.
part 'events_frames.dart';
part 'events_frames_bots.dart';
part 'events_frames_canvas.dart';
part 'events_frames_watch.dart';

/// The envelope version this client speaks. The server refuses a mismatch, so a
/// client that is too old fails at connect rather than misreading frames.
const int protocolVersion = 1;

/// An event pushed by the server.
sealed class ServerEvent {
  const ServerEvent();

  /// Parses a frame, or returns null for anything unrecognized. Unknown frame
  /// types (or a known type with a shape that does not parse) are ignored
  /// rather than fatal, so the server can add events without breaking older
  /// clients.
  static ServerEvent? parse(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (error, stack) {
      AppLog.swallowed(LogTag.sync,
          'Dropped a server event that was not valid JSON', error, stack);
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    try {
      return _fromFrame(decoded);
    } on TypeError catch (error, stack) {
      AppLog.swallowed(LogTag.sync,
          'Dropped a server event with an unexpected shape', error, stack);
      return null;
    } on FormatException catch (error, stack) {
      AppLog.swallowed(LogTag.sync,
          'Dropped a server event with an unexpected shape', error, stack);
      return null;
    }
  }

  static ServerEvent? _fromFrame(Map<String, dynamic> decoded) =>
      coreFrame(decoded) ??
      messageFrame(decoded) ??
      overlayFrame(decoded) ??
      rosterFrame(decoded) ??
      voiceFrame(decoded) ??
      canvasFrame(decoded);
}

/// The server accepted the handshake.
class HelloEvent extends ServerEvent {
  const HelloEvent({required this.protocol});

  final int protocol;
}

/// A message was posted in a channel this session can view.
class MessageCreated extends ServerEvent {
  const MessageCreated(this.message);

  final Message message;
}

/// A message was edited.
class MessageEdited extends ServerEvent {
  const MessageEdited(this.message, {this.opSeq});

  final Message message;

  /// This edit's place in the channel's message-op stream, null against a
  /// server that has none.
  ///
  /// A different number in a different sequence from `message.seq`, which is
  /// the message's own creation order and is unmoved by an edit. The two
  /// sitting adjacent in one frame is the obvious thing to conflate.
  final int? opSeq;
}

/// Keepalive reply.
class PongEvent extends ServerEvent {
  const PongEvent();
}

/// A terminal condition. `resync` means the connection fell behind and was
/// closed, so reconnect and catch up over sync.
class ErrorEvent extends ServerEvent {
  const ErrorEvent(this.message);

  final String message;

  bool get needsResync => message == 'resync';
}
