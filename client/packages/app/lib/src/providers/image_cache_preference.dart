// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The cap on Flutter's decoded-image cache, as a user setting.
///
/// Flutter's own default is 100 MB ([ImageCache.maximumSizeBytes] is
/// `100 << 20`), and that is the default here too, so leaving it alone changes
/// nothing. It is offered because the decoded-image cache is the one Flutter
/// memory pool a person can safely trade down: an evicted image re-decodes
/// from the raw bytes the avatar/attachment caches already hold, so a lower
/// cap costs a little repeated decode work, never a refetch or a blank.
///
/// The cap is bytes of *decoded* pixels held for reuse, not disk and not the
/// raw download; those are bounded separately and by count.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'preference_controller.dart';
import 'providers.dart';

const imageCacheLimitKey = 'slimm.performance.image_cache_mb';

/// The default, matching Flutter's own so the setting is opt-in. Shown in the
/// picker as the "(default)" choice.
const int defaultImageCacheLimitMb = 100;

/// The offered caps. 100 is the default; the lower ones trade decode work for
/// less resident memory, the higher one favours scrolling back through media.
const List<int> imageCacheLimitChoicesMb = [50, 100, 200];

class ImageCacheLimitController extends StateNotifier<int>
    implements RestorablePreference {
  ImageCacheLimitController(this._ref) : super(defaultImageCacheLimitMb) {
    _apply(state);
  }

  final Ref _ref;

  /// A missing or unrecognised stored value leaves the default alone, the same
  /// degrade the display preferences use: a setting a later version dropped
  /// must not throw on an older install.
  @override
  Future<void> restore() async {
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      final stored = prefs.getInt(imageCacheLimitKey);
      if (stored != null && imageCacheLimitChoicesMb.contains(stored)) {
        state = stored;
      }
    } catch (_) {
      // Not worth failing a launch over; the default is always usable.
    }
    _apply(state);
  }

  Future<void> select(int megabytes) async {
    state = megabytes;
    _apply(megabytes);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setInt(imageCacheLimitKey, megabytes);
  }

  void _apply(int megabytes) {
    PaintingBinding.instance.imageCache.maximumSizeBytes = megabytes << 20;
  }
}

final imageCacheLimitControllerProvider =
    StateNotifierProvider<ImageCacheLimitController, int>(
      ImageCacheLimitController.new,
    );
