// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A Space theme's picture, the way a miniature shows it: decoded at the
/// width it is drawn on this screen, never at the file's own size.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/theme_store.dart';

/// [id]'s picture for a miniature [width] logical pixels wide; null when the
/// theme has none, or until it has loaded.
ImageProvider? watchThemePicture(
  WidgetRef ref,
  BuildContext context, {
  required String? id,
  required double width,
}) {
  if (id == null) return null;
  final bytes = ref.watch(spaceThemePictureProvider(id)).valueOrNull;
  if (bytes == null) return null;
  return ResizeImage(
    MemoryImage(bytes),
    width: (width * MediaQuery.devicePixelRatioOf(context)).round(),
    policy: ResizeImagePolicy.fit,
  );
}
