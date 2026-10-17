// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [AvatarCameraCapture] over `image_picker`, for iOS and Android only.
library;

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import 'avatar_photo_menu.dart';

AvatarCameraCapture? createAvatarCameraCapture() {
  final phone =
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;
  return phone ? _captureWithCamera : null;
}

Future<Uint8List?> _captureWithCamera() async {
  final shot = await ImagePicker().pickImage(
    source: ImageSource.camera,
    preferredCameraDevice: CameraDevice.front,
  );
  return shot?.readAsBytes();
}
