// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Platform-facing seams, kept behind interfaces so the app never depends on a
/// specific platform mechanism.
library;

export 'src/apns_token_channel.dart';
export 'src/callkit_incoming_channel.dart';
export 'src/app_lock_window_channel.dart';
export 'src/orientation_channel.dart';
export 'src/biometric_auth_channel.dart';
export 'src/call_lifecycle_channel.dart';
export 'src/call_notifications.dart';
export 'src/clipboard_image_png.dart' show isPng, toPng;
export 'src/clipboard_image_writer.dart';
export 'src/device_name.dart';
export 'src/device_push_keys.dart';
export 'src/fcm_token_channel.dart';
export 'src/game_allowlist.dart';
export 'src/game_source.dart';
export 'src/host_platform.dart';
export 'src/install_format.dart';
export 'src/key_store.dart';
export 'src/local_notifications.dart';
export 'src/notification_tap_channel.dart';
export 'src/now_playing.dart';
export 'src/persistent_key_store.dart';
export 'src/polled_stream.dart';
export 'src/picture_in_picture_channel.dart';
export 'src/shortcuts.dart';
