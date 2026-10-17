// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The small menu a right-click or long-press on an image opens: Copy image
/// and Save image.
///
/// There is no Copy link row: an attachment is served only to signed-in
/// members, so its address is no link anyone could open. A failed action goes
/// up through [onFailure] for the caller to show as an [AppErrorState].
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/context_menu_region.dart';
import 'image_actions.dart';
import 'image_export.dart';

class ImageActionsMenuRegion extends ConsumerWidget {
  const ImageActionsMenuRegion({
    super.key,
    required this.image,
    required this.loadBytes,
    required this.onFailure,
    required this.child,
  });

  final api.Attachment image;

  /// The full-resolution bytes, fetched only when an action runs.
  final Future<Uint8List> Function() loadBytes;

  final ValueChanged<String> onFailure;

  final Widget child;

  Future<void> _run(
    Future<String?> Function(
      WidgetRef ref,
      api.Attachment image,
      Future<Uint8List> Function() loadBytes,
    )
    action,
    WidgetRef ref,
  ) async {
    final failure = await action(ref, image, loadBytes);
    if (failure != null) onFailure(failure);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final savesToLibrary = ref.watch(imageExporterProvider).savesToLibrary;
    return ContextMenuRegion(
      itemsBuilder: (context, close) => [
        AppMenuItem(
          label: 'Copy image',
          leading: AppIcons.copy,
          onTap: () {
            close();
            _run(copyImageToClipboard, ref);
          },
        ),
        AppMenuItem(
          label: savesToLibrary ? 'Save to photos' : 'Save image',
          leading: AppIcons.download,
          onTap: () {
            close();
            _run(saveImageToDevice, ref);
          },
        ),
      ],
      child: child,
    );
  }
}
