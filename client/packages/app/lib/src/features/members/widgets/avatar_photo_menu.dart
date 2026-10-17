// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The menu the profile picture opens: take, choose, browse, remove.
///
/// One `showAppSheet` call, so it is a bottom sheet with handle and 44dp rows
/// under `kCompactWidth` and the floating menu above it (rule 3 of
/// `docs/design/desktop-vs-mobile.md`).
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import 'avatar_camera_none.dart'
    if (dart.library.io) 'avatar_camera_native.dart';

enum AvatarPhotoAction { take, choose, browse, remove }

/// Captures one photo with the camera, or null when the user backs out.
typedef AvatarCameraCapture = Future<Uint8List?> Function();

/// Null where the device has no camera to capture from (web, desktop), which
/// hides "Take photo"; a capability check, never a layout decision.
final avatarCameraCaptureProvider = Provider<AvatarCameraCapture?>(
  (ref) => createAvatarCameraCapture(),
);

Future<AvatarPhotoAction?> showAvatarPhotoMenu(
  BuildContext context, {
  required bool canTake,
  required bool canRemove,
}) {
  return showAppSheet<AvatarPhotoAction>(
    context,
    bare: true,
    builder: (sheetContext) {
      void pick(AvatarPhotoAction action) =>
          Navigator.of(sheetContext).pop(action);
      return AppSheetMenu(
        children: [
          if (canTake)
            AppMenuItem(
              label: 'Take photo',
              leading: AppIcons.avatarCamera,
              onTap: () => pick(AvatarPhotoAction.take),
            ),
          AppMenuItem(
            label: 'Choose photo',
            leading: AppIcons.image,
            onTap: () => pick(AvatarPhotoAction.choose),
          ),
          AppMenuItem(
            label: 'Browse files',
            leading: AppIcons.attachFile,
            onTap: () => pick(AvatarPhotoAction.browse),
          ),
          if (canRemove)
            AppMenuItem(
              label: 'Remove photo',
              leading: AppIcons.delete,
              tone: AppMenuItemTone.danger,
              onTap: () => pick(AvatarPhotoAction.remove),
            ),
        ],
      );
    },
  );
}
