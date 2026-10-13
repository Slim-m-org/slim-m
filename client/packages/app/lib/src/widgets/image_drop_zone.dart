// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An [AppDropZone] for a surface that takes exactly one still picture: an
/// avatar, the Space banner or icon. It decides what a drop means; the caller
/// only handles the bytes, through the same path a picked file takes.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'app_drop_zone.dart';

/// The picture types every surface accepts as a still image.
const stillImageExtensions = ['png', 'jpg', 'jpeg', 'webp'];

const _refusal = 'Drop one PNG, JPEG or WebP picture.';

/// What a drop amounted to: one picture's bytes, or why it was refused.
sealed class ImageDrop {
  const ImageDrop();
}

final class DroppedImage extends ImageDrop {
  const DroppedImage(this.bytes, this.name);
  final Uint8List bytes;
  final String name;
}

final class RefusedDrop extends ImageDrop {
  const RefusedDrop(this.message);
  final String message;
}

/// Reads [items] as one still picture, judged by its extension before any
/// bytes are read, so a dropped video is refused without loading it.
Future<ImageDrop> readDroppedImage(List<DropItem> items) async {
  if (items.length != 1 || items.single is DropItemDirectory) {
    return const RefusedDrop(_refusal);
  }
  final item = items.single;
  final dot = item.name.lastIndexOf('.');
  final extension = dot < 0 ? '' : item.name.substring(dot + 1).toLowerCase();
  if (!stillImageExtensions.contains(extension)) {
    return const RefusedDrop(_refusal);
  }
  return DroppedImage(await item.readAsBytes(), item.name);
}

class ImageDropZone extends StatelessWidget {
  const ImageDropZone({
    super.key,
    required this.enabled,
    required this.onImage,
    required this.onRejected,
    required this.child,
    this.label = 'Drop a picture',
  });

  final bool enabled;
  final String label;
  final void Function(Uint8List bytes, String name) onImage;
  final ValueChanged<String> onRejected;
  final Widget child;

  Future<void> _handle(List<DropItem> items) async {
    switch (await readDroppedImage(items)) {
      case DroppedImage(:final bytes, :final name):
        onImage(bytes, name);
      case RefusedDrop(:final message):
        onRejected(message);
    }
  }

  @override
  Widget build(BuildContext context) => AppDropZone(
    enabled: enabled,
    label: label,
    icon: AppIcons.image,
    onDrop: (items) => unawaited(_handle(items)),
    child: child,
  );
}
