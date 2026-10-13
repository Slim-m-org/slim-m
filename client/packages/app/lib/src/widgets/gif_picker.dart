// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's GIF picker: a search field, a debounced request, and a
/// grid of results streamed through this deployment's own server. Opens on
/// trending results rather than a blank grid, the same "something to look
/// at before you type" behavior Discord's own picker has - clearing the
/// query falls back to the same trending grid rather than emptying it.
/// Nothing here ever reaches the configured provider directly - `searchGifs`,
/// `fetchTrendingGifs`, `fetchGifPreview` and `selectGif` all proxy through
/// [SlimmApiGifs] - and the whole surface is only ever shown when
/// `Version.gifSearchEnabled` is true; see `composer.dart` for that check.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../api_failure.dart';
import '../providers/gif_preview_bytes.dart';
import '../providers/gif_trending.dart';
import '../providers/providers.dart';
import 'composer_attachments.dart';
import 'image_decode.dart';

/// How long a pause in typing must last before a search actually fires, so a
/// fast typist does not spend a request per keystroke.
const _searchDebounce = Duration(milliseconds: 400);

/// The most the grid may take on a roomy screen: a ceiling, not a fixed
/// height, so a short result list does not force the sheet to a tall empty
/// box - `_SpaceEmojiSheet`'s own precedent.
const double _maxGridHeight = 340;

/// Below this the grid stops giving ground and scrolls instead, rather than
/// shrinking until it shows nothing.
const double _minGridHeight = 120;

/// What the panel needs around the grid: the sheet's drag handle, its own
/// padding, the search field and the gap under it.
const double _chromeHeight = 140;

/// The grid's ceiling for the room actually available.
///
/// Derived rather than constant because this picker's field autofocuses, so
/// the keyboard is up the entire time it is open - not an edge case, every
/// time. A fixed 340 is comfortable on a tall phone with no keyboard and
/// overflows its column by 382 pixels on a 640-tall one with a 300-tall
/// keyboard, which is what `gif_picker_keyboard_test.dart` pins.
double gifGridCeiling(BuildContext context) {
  final available =
      MediaQuery.sizeOf(context).height -
      MediaQuery.viewInsetsOf(context).bottom;
  return (available - _chromeHeight).clamp(_minGridHeight, _maxGridHeight);
}

/// Opens the GIF picker as a sheet. [onPicked] runs after the sheet has
/// popped, the same convention `showEmojiPickerSheet` already uses, so a
/// caller re-focusing the composer is never fighting the closing route.
Future<void> showGifPickerSheet(
  BuildContext context, {
  required ValueChanged<api.Attachment> onPicked,
}) {
  return showAppSheet<void>(
    context,
    maxWidth: 480,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: GifPickerBody(
          onPicked: (attachment) {
            Navigator.of(context).pop();
            onPicked(attachment);
          },
        ),
      ),
    ),
  );
}

/// Fetches a freshly picked GIF's own bytes back once (`selectGif` already
/// stored them server side; this is only for the newly staged tile's own
/// local preview) and stages it - or hands [onError] a sentence, never a
/// raw exception, if that last step fails. Shared by [pickGif]'s sheet flow
/// and the desktop anchored panel `composer_picker_panel.dart` opens instead.
Future<void> stageGif({
  required BuildContext context,
  required WidgetRef ref,
  required AttachmentStagingController attachments,
  required ValueChanged<String?> onError,
  required api.Attachment attachment,
}) async {
  try {
    final bytes = await ref.read(apiProvider).fetchAttachment(attachment.id);
    // The composer may have been torn down while this awaited.
    if (!context.mounted) return;
    attachments.addResolved(attachment, bytes.bytes);
  } on api.ApiException catch (e) {
    onError(describeApiFailure('attach that gif', e));
  }
}

/// The whole flow the composer's touch-density GIF entry point needs: open
/// the sheet, then [stageGif] once something is picked.
Future<void> pickGif({
  required BuildContext context,
  required WidgetRef ref,
  required AttachmentStagingController attachments,
  required ValueChanged<String?> onError,
}) {
  return showGifPickerSheet(
    context,
    onPicked: (attachment) => stageGif(
      context: context,
      ref: ref,
      attachments: attachments,
      onError: onError,
      attachment: attachment,
    ),
  );
}

/// The picker's content: search field, trending/search grid, nothing else.
/// Exposed (not `_`-private) so `composer_picker_panel.dart` can embed it as
/// one tab of the composer's own anchored picker rather than a sheet;
/// [onPicked] is this widget's only opinion about closing anything - the
/// sheet built by [showGifPickerSheet] pops itself before calling it, and
/// the anchored panel closes its own overlay the same way.
class GifPickerBody extends ConsumerStatefulWidget {
  const GifPickerBody({
    super.key,
    required this.onPicked,
    this.initialQuery = '',
  });

  final ValueChanged<api.Attachment> onPicked;

  /// Searched for straight away, as `/gif cats` asks.
  final String initialQuery;

  @override
  ConsumerState<GifPickerBody> createState() => _GifPickerBodyState();
}

class _GifPickerBodyState extends ConsumerState<GifPickerBody> {
  final _queryController = TextEditingController();
  final _queryFocus = FocusNode();
  Timer? _debounce;

  bool _loading = false;
  String? _error;
  List<api.GifResult>? _results;

  /// The result currently being picked, so its own tile can show a spinner
  /// and every other tile is disabled until this one resolves.
  String? _selectingId;

  @override
  void initState() {
    super.initState();
    final query = widget.initialQuery.trim();
    _queryController.text = query;
    // Asked for, not autofocus alone: autofocus yields to the composer when it already holds focus, as it does for /gif.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _queryFocus.requestFocus();
      if (query.isNotEmpty) unawaited(_search(query));
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryController.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      // Falls back to the trending grid rather than a blank one.
      setState(() {
        _results = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    _debounce = Timer(_searchDebounce, () => unawaited(_search(query)));
  }

  Future<void> _search(String query) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await ref.read(apiProvider).searchGifs(query);
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } on api.ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeApiFailure('search for gifs', e);
        _loading = false;
      });
    }
  }

  Future<void> _pick(api.GifResult result) async {
    setState(() {
      _selectingId = result.id;
      _error = null;
    });
    try {
      final attachment = await ref.read(apiProvider).selectGif(result.id);
      if (!mounted) return;
      widget.onPicked(attachment);
    } on api.NotFoundException {
      // Every tile is stale, not just this one; reload rather than report. See gifGridCeiling's neighbours.
      if (!mounted) return;
      setState(() => _selectingId = null);
      await _reload();
    } on api.ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeApiFailure('attach that gif', e);
        _selectingId = null;
      });
    }
  }

  /// Re-runs whatever is on screen - the current search, or trending when the
  /// box is empty - so the grid comes back with tokens that still redeem.
  /// Invalidating [trendingGifsProvider] rather than re-reading it directly:
  /// the provider is cached for the session (see its own doc comment), so a
  /// stale-token reload has to force a real refetch, not just re-read the
  /// same cached list that just failed to redeem.
  Future<void> _reload() {
    final query = _queryController.text.trim();
    if (query.isEmpty) {
      ref.invalidate(trendingGifsProvider);
      return Future.value();
    }
    return _search(query);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final trending = ref.watch(trendingGifsProvider);
    // Only shown once nothing has been searched: a search failure reports through _error instead, and the two must not both claim the one banner slot.
    final trendingError = _results == null && trending.hasError
        ? _describeTrendingFailure(trending.error)
        : null;
    final error = _error ?? trendingError;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppInput(
            maxLength: api.InputLimits.searchQuery,
            controller: _queryController,
            focusNode: _queryFocus,
            autofocus: true,
            placeholder: 'Search GIFs',
            icon: Icon(
              AppIcons.search,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            ),
            onChanged: _onQueryChanged,
            semanticLabel: 'Search GIFs',
          ),
          const SizedBox(height: AppSpacing.s12),
          if (error != null) ...[
            AppErrorState(
              message: error,
              onRetry: trendingError != null
                  ? () => ref.invalidate(trendingGifsProvider)
                  : null,
            ),
            const SizedBox(height: AppSpacing.s12),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: gifGridCeiling(context)),
            child: _content(tokens, trending),
          ),
        ],
      ),
    );
  }

  Widget _content(AppTokens tokens, AsyncValue<List<api.GifResult>> trending) {
    if (_loading || (_results == null && trending.isLoading)) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.s24),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final results = _results ?? trending.valueOrNull;
    if (results == null) {
      // Trending failed and nothing has been searched; the banner above explains.
      return const SizedBox.shrink();
    }
    if (results.isEmpty) {
      return Center(
        child: Text(
          'No matches.',
          style: AppText.body.copyWith(color: tokens.textSecondary),
        ),
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        crossAxisSpacing: AppSpacing.s8,
        mainAxisSpacing: AppSpacing.s8,
        childAspectRatio: 1.3,
      ),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final result = results[index];
        return _GifTile(
          result: result,
          busy: _selectingId != null,
          selecting: _selectingId == result.id,
          onTap: () => unawaited(_pick(result)),
        );
      },
    );
  }
}

/// [trendingGifsProvider]'s own error, described the same way a caught
/// [api.ApiException] would be - it never surfaces as anything else, since
/// [SlimmApiGifs.fetchTrendingGifs] never throws otherwise - but `AsyncValue
/// .error` is typed `Object?`, so this still falls back to a generic
/// sentence rather than a cast that could throw from inside a build method.
String _describeTrendingFailure(Object? error) => error is api.ApiException
    ? describeApiFailure('load trending gifs', error)
    : 'Could not load trending gifs.';

class _GifTile extends ConsumerWidget {
  const _GifTile({
    required this.result,
    required this.busy,
    required this.selecting,
    required this.onTap,
  });

  final api.GifResult result;

  /// Whether *some* tile in the grid is currently being picked - every tile
  /// is disabled while that is true, not only the one selected.
  final bool busy;
  final bool selecting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final preview = ref.watch(gifPreviewBytesProvider(result.id));
    return Semantics(
      button: true,
      label: result.title.isEmpty ? 'Pick a GIF' : 'Pick: ${result.title}',
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.control),
          child: ColoredBox(
            color: tokens.surfaceBase,
            child: Stack(
              fit: StackFit.expand,
              children: [
                switch (preview) {
                  AsyncData(value: final Uint8List bytes) => Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    cacheWidth: decodeEdge(context, 160),
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                  AsyncError() => const SizedBox.shrink(),
                  _ => const Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                },
                if (selecting)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: tokens.surfaceBase.withValues(alpha: 0.65),
                    ),
                    child: const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
