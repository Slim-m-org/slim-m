// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone composer's recent-photos panel, shown where the keyboard sits: a
/// vertical grid of the camera roll that swipes down to close.
///
/// Rule 4 of `docs/design/desktop-vs-mobile.md` is the nearest surface (a short
/// task under 600dp lives at the bottom of the screen), but it is docked in the
/// composer column rather than a modal sheet so the thread stays visible.
/// Width decides: at `kCompactWidth` and above this draws nothing.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/server_info.dart';
import 'photo_library.dart';
import 'photo_size_note.dart';
import 'photo_strip_tiles.dart';
import 'staged_attachment_model.dart';
import 'package:slimm_api/api.dart' show LogTag, reportFailure;

/// Whether a channel's composer has its photo strip open.
final photoStripOpenProvider = StateProvider.autoDispose.family<bool, String>(
  (ref, channelId) => false,
);

/// Opens the strip on a phone with a photo library, else runs [fallback], the
/// system picker, so the same menu entry works at every width and on web.
void openPhotoStripOr(
  BuildContext context,
  WidgetRef ref,
  String channelId, {
  required VoidCallback fallback,
}) {
  final onPhone = MediaQuery.sizeOf(context).width < kCompactWidth;
  if (onPhone && ref.read(photoLibraryProvider) != null) {
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(photoStripOpenProvider(channelId).notifier).state = true;
  } else {
    fallback();
  }
}

/// The strip while [photoStripOpenProvider] says so, otherwise nothing.
class ComposerPhotoStripSlot extends ConsumerWidget {
  const ComposerPhotoStripSlot({
    super.key,
    required this.channelId,
    required this.stageFile,
    required this.onBrowse,
  });

  final String channelId;
  final Future<void> Function(FileSource file) stageFile;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(photoStripOpenProvider(channelId))) {
      return const SizedBox.shrink();
    }
    return ComposerPhotoStrip(
      onAttach: stageFile,
      onBrowse: onBrowse,
      onClose: () =>
          ref.read(photoStripOpenProvider(channelId).notifier).state = false,
    );
  }
}

const _readFailure = 'Could not read that photo.';

/// How many recent photos each page of the grid loads.
const int _pageSize = 60;

/// How far, or how fast, a downward drag must go to close the panel.
const double _closeDistance = 80;
const double _closeVelocity = 700;

class ComposerPhotoStrip extends ConsumerStatefulWidget {
  const ComposerPhotoStrip({
    super.key,
    required this.onAttach,
    required this.onBrowse,
    required this.onClose,
  });

  /// Hands one photo to the composer's own staging path.
  final Future<void> Function(FileSource photo) onAttach;

  /// Opens the full system picker, the way out of denied or limited access.
  final VoidCallback onBrowse;
  final VoidCallback onClose;

  @override
  ConsumerState<ComposerPhotoStrip> createState() => _ComposerPhotoStripState();
}

class _ComposerPhotoStripState extends ConsumerState<ComposerPhotoStrip>
    with SingleTickerProviderStateMixin {
  PhotoAccess? _access;
  List<RecentPhoto> _photos = const [];
  String? _problem;

  /// Photos whose original is being read; a repeat tap on one is ignored.
  final Set<String> _fetching = {};

  /// How many photos have been asked for; grows a page at a time near the end.
  int _requested = _pageSize;
  bool _exhausted = false;
  bool _loadingMore = false;

  /// How far a swipe-down has pulled the panel.
  double _drag = 0;

  /// Springs a short pull back to rest.
  late final AnimationController _settle =
      AnimationController(vsync: this, duration: AppMotion.base)..addListener(
        () => setState(() => _drag = _settleFrom * (1 - _settle.value)),
      );
  double _settleFrom = 0;

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final library = ref.read(photoLibraryProvider);
    if (library == null) return;
    var access = PhotoAccess.denied;
    var photos = const <RecentPhoto>[];
    try {
      access = await library.requestAccess();
      if (access != PhotoAccess.denied) {
        photos = await library.recent(_requested);
      }
    } catch (error, stack) {
      reportFailure(LogTag.ui, 'load recent photos', error, stack);
      // A plugin that cannot read the library lands on the same way out as a refusal.
      access = PhotoAccess.denied;
    }
    if (!mounted) return;
    setState(() {
      _access = access;
      _photos = photos;
      _exhausted = photos.length < _requested;
    });
  }

  Future<void> _loadMore() async {
    final library = ref.read(photoLibraryProvider);
    if (library == null || _exhausted || _loadingMore) return;
    _loadingMore = true;
    _requested += _pageSize;
    try {
      final photos = await library.recent(_requested);
      if (!mounted) return;
      setState(() {
        _photos = photos;
        _exhausted = photos.length < _requested;
      });
    } catch (error, stack) {
      reportFailure(LogTag.ui, 'load more photos', error, stack);
      // The page already shown stays; scrolling to the end again retries.
      _requested -= _pageSize;
    } finally {
      _loadingMore = false;
    }
  }

  void _dragBy(double dy) {
    _settle.stop();
    setState(() => _drag = (_drag + dy).clamp(0, double.infinity));
  }

  void _dragEnd(double velocity) {
    if (_drag >= _closeDistance || velocity >= _closeVelocity) {
      AppHaptics.selection();
      widget.onClose();
      return;
    }
    _settleFrom = _drag;
    unawaited(_settle.forward(from: 0));
  }

  bool _onScroll(ScrollNotification n) {
    final atTop = n.metrics.pixels <= n.metrics.minScrollExtent;
    if (n is OverscrollNotification && n.dragDetails != null && atTop) {
      if (n.overscroll < 0) _afterLayout(() => _dragBy(-n.overscroll));
    } else if (n is ScrollUpdateNotification &&
        n.dragDetails != null &&
        _drag > 0 &&
        (n.scrollDelta ?? 0) > 0) {
      _afterLayout(() => _dragBy(-(n.scrollDelta ?? 0)));
    } else if (n is ScrollEndNotification && _drag > 0) {
      final velocity = n.dragDetails?.primaryVelocity ?? 0;
      _afterLayout(() => _dragEnd(velocity));
    }
    if (n.metrics.extentAfter < photoStripMaxTileExtent * 3) {
      _afterLayout(() => unawaited(_loadMore()));
    }
    return false;
  }

  /// Runs [change] now, or after this frame when a notification arrives mid-layout.
  void _afterLayout(VoidCallback change) {
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      change();
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) change();
    });
  }

  Future<void> _manage() async {
    await ref.read(photoLibraryProvider)?.manageLimited();
    if (mounted) await _load();
  }

  Future<void> _attach(RecentPhoto photo) async {
    if (!_fetching.add(photo.id)) return;
    setState(() {});
    try {
      await _readAndAttach(photo);
    } finally {
      _fetching.remove(photo.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _readAndAttach(RecentPhoto photo) async {
    final tooBig = oversizeNote(photo.bytes, await _uploadLimit());
    if (!mounted) return;
    if (tooBig != null) {
      setState(() => _problem = tooBig);
      return;
    }
    final FileSource? original;
    try {
      original = await ref.read(photoLibraryProvider)?.original(photo.id);
    } on Object catch (error, stack) {
      reportFailure(LogTag.ui, 'read a library photo', error, stack);
      if (mounted) setState(() => _problem = _readFailure);
      return;
    }
    if (!mounted) return;
    if (original == null) {
      setState(() => _problem = _readFailure);
      return;
    }
    setState(() => _problem = null);
    await widget.onAttach(original);
  }

  /// The server's per-file ceiling, or null when it cannot be learned quickly.
  Future<int?> _uploadLimit() async {
    try {
      final version = await ref
          .read(serverInfoProvider.future)
          .timeout(const Duration(seconds: 3));
      return version.maxAttachmentBytes;
    } on Object catch (error, stack) {
      reportFailure(
        LogTag.media,
        "read the server's attachment limit",
        error,
        stack,
      );
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (size.width >= kCompactWidth) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final access = _access;
    final height = (size.height * 0.42).clamp(240.0, 400.0);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s8),
      child: Transform.translate(
        offset: Offset(0, _drag),
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: tokens.surfaceSunken,
            borderRadius: BorderRadius.circular(AppRadii.card),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                button: true,
                label: 'Close photo strip',
                onTap: widget.onClose,
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onClose,
                  onVerticalDragUpdate: (d) => _dragBy(d.delta.dy),
                  onVerticalDragEnd: (d) => _dragEnd(d.primaryVelocity ?? 0),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.s8,
                    ),
                    child: Center(
                      child: PhotoStripGrabHandle(color: tokens.borderStrong),
                    ),
                  ),
                ),
              ),
              if (access == PhotoAccess.limited) _limitedNote(tokens),
              if (_problem != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s8,
                  ),
                  child: AppErrorState(
                    message: _problem!,
                    onDismiss: () => setState(() => _problem = null),
                  ),
                ),
              Expanded(
                child: switch (access) {
                  null => const Center(
                    child: AppSpinner(size: AppSpinnerSize.lg),
                  ),
                  PhotoAccess.denied => SingleChildScrollView(
                    child: _denied(tokens),
                  ),
                  _ => _grid(),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Only a limited grant says anything above the grid: which photos these are, and how to widen it.
  Widget _limitedNote(AppTokens tokens) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            'Showing the photos you allowed',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ),
        AppButton(
          label: 'Allow more',
          variant: AppButtonVariant.ghost,
          onPressed: () => unawaited(_manage()),
        ),
      ],
    ),
  );

  Widget _denied(AppTokens tokens) => Padding(
    padding: const EdgeInsets.all(AppSpacing.s8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'slim-m cannot see your photos. Allow photo access in Settings, '
          'or browse them in the system picker.',
          style: AppText.ui.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s8),
        AppButton(
          label: 'Browse photos',
          icon: AppIcons.image,
          onPressed: widget.onBrowse,
        ),
      ],
    ),
  );

  Widget _grid() => NotificationListener<ScrollNotification>(
    onNotification: _onScroll,
    child: GridView.builder(
      padding: const EdgeInsets.all(AppSpacing.s8),
      physics: const ClampingScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: photoStripMaxTileExtent,
        mainAxisSpacing: AppSpacing.s4,
        crossAxisSpacing: AppSpacing.s4,
      ),
      itemCount: _photos.length + 1,
      itemBuilder: (context, i) => i == 0
          ? AllPhotosTile(onTap: widget.onBrowse)
          : PhotoStripTile(
              key: ValueKey(_photos[i - 1].id),
              photo: _photos[i - 1],
              busy: _fetching.contains(_photos[i - 1].id),
              onTap: () => _attach(_photos[i - 1]),
            ),
    ),
  );
}
