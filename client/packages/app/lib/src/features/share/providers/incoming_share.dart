// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the OS share sheet handed the app, and where it waits until the
/// person has chosen a conversation for it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One file the OS shared, already copied into the app's cache.
class SharedFile {
  const SharedFile({
    required this.path,
    required this.name,
    required this.length,
    this.mimeType,
  });

  final String path;
  final String name;
  final int length;
  final String? mimeType;

  bool get isImage => mimeType?.startsWith('image/') ?? false;
  bool get isVideo => mimeType?.startsWith('video/') ?? false;
}

/// A share: files, text, or both.
class IncomingShare {
  const IncomingShare({this.files = const [], this.text, this.unreadable = 0});

  /// Null when the platform sent nothing usable, so a stray intent opens no picker.
  static IncomingShare? fromWire(Object? wire) {
    if (wire is! Map) return null;
    final files = <SharedFile>[];
    for (final entry in wire['files'] as List<Object?>? ?? const []) {
      if (entry is! Map) continue;
      final path = entry['path'];
      final name = entry['name'];
      if (path is! String || name is! String) continue;
      files.add(
        SharedFile(
          path: path,
          name: name,
          length: (entry['length'] as num?)?.toInt() ?? 0,
          mimeType: entry['mimeType'] as String?,
        ),
      );
    }
    final rawText = wire['text'];
    final text = rawText is String && rawText.trim().isNotEmpty
        ? rawText
        : null;
    final unreadable = (wire['unreadable'] as num?)?.toInt() ?? 0;
    if (files.isEmpty && text == null && unreadable == 0) return null;
    return IncomingShare(files: files, text: text, unreadable: unreadable);
  }

  final List<SharedFile> files;
  final String? text;

  /// How many shared items the platform would not let the app read.
  final int unreadable;

  bool get hasFiles => files.isNotEmpty;
  bool get hasText => text != null;
}

/// A share waiting for the person to choose where it goes.
class PendingShare {
  const PendingShare(this.share, {this.serverChosen = false});

  final IncomingShare share;

  /// The person has said which server this goes to, so the picker stops asking.
  final bool serverChosen;
}

/// The share waiting for a conversation, per account container. Cleared the
/// moment a conversation is chosen or the picker is dismissed.
final pendingShareProvider = StateProvider<PendingShare?>((ref) => null);

/// A share that has been given a conversation and waits for that
/// conversation's composer to mount so it can stage the files.
typedef ShareHandoff = ({String channelId, IncomingShare share});

final shareHandoffProvider = StateProvider<ShareHandoff?>((ref) => null);
