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

import '../../../providers/preference_controller.dart';
import '../../../providers/providers.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const imageCacheLimitKey = 'slimm.performance.image_cache_mb';

/// The default, matching Flutter's own so the setting is opt-in. Shown in the
/// picker as the "(default)" choice.
const int defaultImageCacheLimitMb = 100;

/// The stored value for no cap at all.
const int imageCacheNoLimitMb = 0;

/// The offered caps. 100 is the default; the lower ones trade decode work for
/// less resident memory, the higher ones favour scrolling back through media.
const List<int> imageCacheLimitChoicesMb = [
  50,
  100,
  200,
  500,
  1000,
  imageCacheNoLimitMb,
];

/// How a cap reads in the picker.
String imageCacheLimitLabel(int megabytes) => switch (megabytes) {
  imageCacheNoLimitMb => 'No limit',
  defaultImageCacheLimitMb => '$megabytes MB (default)',
  1000 => '1 GB',
  _ => '$megabytes MB',
};

/// Flutter's own entry-count cap, which No limit lifts along with the bytes.
const int _defaultImageCacheEntries = 1000;

/// No limit's caps: far past any real heap, and below 2^53 so the web holds them exactly.
const int _noLimitBytes = 1000000000000000;
const int _noLimitEntries = 1000000000;

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
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.media,
        'Could not read the image cache setting; using the default',
        error,
        stack,
      );
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
    final cache = PaintingBinding.instance.imageCache;
    if (megabytes == imageCacheNoLimitMb) {
      cache.maximumSizeBytes = _noLimitBytes;
      cache.maximumSize = _noLimitEntries;
      return;
    }
    cache.maximumSizeBytes = megabytes << 20;
    cache.maximumSize = _defaultImageCacheEntries;
  }
}

final imageCacheLimitControllerProvider =
    StateNotifierProvider<ImageCacheLimitController, int>(
      ImageCacheLimitController.new,
    );
