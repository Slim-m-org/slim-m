// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The personal background: whether there is a picture, how it is treated,
/// and importing or removing one.
///
/// The picture's bytes live in [BackgroundImageStore]; only the small settings
/// and the picture's tonal range live in shared preferences.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/preference_controller.dart';
import '../../../providers/providers.dart';
import '../../../providers/bounded_image_decode.dart';
import 'background_image_store.dart';
import 'background_tone.dart';

const backgroundHasImageKey = 'slimm.appearance.background.has_image';
const backgroundDimKey = 'slimm.appearance.background.dim';
const backgroundVignetteKey = 'slimm.appearance.background.vignette';
const backgroundBlurKey = 'slimm.appearance.background.blur';
const backgroundToneKey = 'slimm.appearance.background.tone';

/// The longest side a picture is kept at, so memory stays small.
const backgroundMaxSide = 2560;

/// A picture this large is refused before any pixel is allocated.
const backgroundMaxSourcePixels = 100 * 1000 * 1000;

class AppBackgroundSettings {
  const AppBackgroundSettings({
    this.hasImage = false,
    this.revision = 0,
    this.dim = kBackgroundDefaultDim,
    this.vignette = true,
    this.blur = 0,
    this.range = PictureRange.worst,
  });

  final bool hasImage;

  /// Bumped on every import so a held decode is dropped.
  final int revision;
  final double dim;
  final bool vignette;
  final double blur;
  final PictureRange range;

  /// The treatment to paint under [tokens]: [dim] raised to what keeps text
  /// readable over this picture.
  AppBackgroundStyle styleFor(AppTokens tokens) => AppBackgroundStyle(
    dim: effectiveBackgroundDim(tokens, dim, range),
    vignette: vignette,
    blur: blur,
  );

  /// The lowest fade a person may pick under [tokens], on the slider's 5% steps.
  double minimumDimFor(AppTokens tokens) =>
      (minimumBackgroundDim(tokens, range) * 20).ceil() / 20;

  AppBackgroundSettings copyWith({
    bool? hasImage,
    int? revision,
    double? dim,
    bool? vignette,
    double? blur,
    PictureRange? range,
  }) => AppBackgroundSettings(
    hasImage: hasImage ?? this.hasImage,
    revision: revision ?? this.revision,
    dim: dim ?? this.dim,
    vignette: vignette ?? this.vignette,
    blur: blur ?? this.blur,
    range: range ?? this.range,
  );
}

class AppBackgroundController extends Notifier<AppBackgroundSettings>
    implements RestorablePreference {
  AppBackgroundController([this._initial = const AppBackgroundSettings()]);

  final AppBackgroundSettings _initial;

  @override
  AppBackgroundSettings build() => _initial;

  @override
  Future<void> restore() async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      final tone = prefs.getStringList(backgroundToneKey);
      state = state.copyWith(
        hasImage: prefs.getBool(backgroundHasImageKey) ?? false,
        dim: (prefs.getDouble(backgroundDimKey) ?? kBackgroundDefaultDim).clamp(
          0.0,
          kBackgroundMaxDim,
        ),
        vignette: prefs.getBool(backgroundVignetteKey) ?? true,
        blur: (prefs.getDouble(backgroundBlurKey) ?? 0).clamp(0.0, 1.0),
        range: tone == null ? PictureRange.worst : rangeFromStrings(tone),
      );
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.data,
        'Could not read the saved background; using none',
        error,
        stack,
      );
    }
  }

  /// Keeps [bytes], shrunk to [backgroundMaxSide], as the background.
  /// False when it is not a picture this device can read or keep.
  Future<bool> importPicture(Uint8List bytes) async {
    final prepared = await prepareBackground(
      bytes,
      maxSide: backgroundMaxSide,
      maxSourcePixels: backgroundMaxSourcePixels,
    );
    if (prepared == null) return false;
    final store = ref.read(backgroundImageStoreProvider);
    if (!await store.write(prepared.png)) return false;
    try {
      final prefs = await ref.read(preferencesProvider.future);
      await prefs.setBool(backgroundHasImageKey, true);
      await prefs.setStringList(
        backgroundToneKey,
        rangeToStrings(prepared.range),
      );
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.data,
        'Could not save the background settings; dropping the picture',
        error,
        stack,
      );
      await _dropUnsavedPicture(store);
      return false;
    }
    state = state.copyWith(
      hasImage: true,
      revision: state.revision + 1,
      range: prepared.range,
    );
    return true;
  }

  /// The picture on disk would outlive a restart without its settings, so no picture is kept at all.
  Future<void> _dropUnsavedPicture(BackgroundImageStore store) async {
    await store.clear();
    state = state.copyWith(hasImage: false, revision: state.revision + 1);
    try {
      final prefs = await ref.read(preferencesProvider.future);
      await prefs.setBool(backgroundHasImageKey, false);
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.data,
        'Could not reset the background flag',
        error,
        stack,
      );
    }
  }

  Future<void> remove() async {
    state = state.copyWith(hasImage: false, revision: state.revision + 1);
    await ref.read(backgroundImageStoreProvider).clear();
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setBool(backgroundHasImageKey, false);
  }

  Future<void> setDim(double value) async {
    state = state.copyWith(dim: value.clamp(0.0, kBackgroundMaxDim));
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setDouble(backgroundDimKey, state.dim);
  }

  Future<void> setVignette(bool value) async {
    state = state.copyWith(vignette: value);
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setBool(backgroundVignetteKey, value);
  }

  Future<void> setBlur(double value) async {
    state = state.copyWith(blur: value.clamp(0.0, 1.0));
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setDouble(backgroundBlurKey, state.blur);
  }
}

final appBackgroundControllerProvider =
    NotifierProvider<AppBackgroundController, AppBackgroundSettings>(
      AppBackgroundController.new,
    );

/// Owns the decoded bitmap and releases a replaced one only once its successor
/// is ready, so a widget still painting it never holds a disposed image.
class _PictureSlot {
  ui.Image? _held;

  void replace(ui.Image? next) {
    final previous = _held;
    _held = next;
    previous?.dispose();
  }
}

/// Outlives the picture provider's own rebuilds, and ends with its last listener.
final _pictureSlotProvider = Provider.autoDispose<_PictureSlot>((ref) {
  final slot = _PictureSlot();
  ref.onDispose(() => slot.replace(null));
  return slot;
});

/// The decoded picture, held once for as long as something shows it.
final backgroundPictureProvider = FutureProvider.autoDispose<ui.Image?>((
  ref,
) async {
  final slot = ref.watch(_pictureSlotProvider);
  final settings = ref.watch(
    appBackgroundControllerProvider.select((s) => (s.hasImage, s.revision)),
  );
  var current = true;
  ref.onDispose(() => current = false);
  if (!settings.$1) {
    slot.replace(null);
    return null;
  }
  final bytes = await ref.read(backgroundImageStoreProvider).read();
  if (!current) return null;
  if (bytes == null) {
    slot.replace(null);
    return null;
  }
  try {
    final image = await decodeBoundedImage(bytes, maxSide: backgroundMaxSide);
    if (!current) {
      image.dispose();
      return null;
    }
    slot.replace(image);
    return image;
  } catch (error, stack) {
    AppLog.swallowed(
      LogTag.media,
      'Could not decode the background picture',
      error,
      stack,
    );
    if (current) slot.replace(null);
    return null;
  }
});
