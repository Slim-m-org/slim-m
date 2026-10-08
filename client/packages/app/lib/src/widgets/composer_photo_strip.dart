// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone composer's recent-photos strip, shown where the keyboard sits.
///
/// Rule 4 of `docs/design/desktop-vs-mobile.md` is the nearest surface (a short
/// task under 600dp lives at the bottom of the screen), but it is docked in the
/// composer column rather than a modal sheet so the thread stays visible.
/// Width decides: at `kCompactWidth` and above this draws nothing.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import 'photo_library.dart';

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
    required this.stage,
    required this.onBrowse,
  });

  final String channelId;
  final Future<void> Function(Uint8List bytes, String filename) stage;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(photoStripOpenProvider(channelId))) {
      return const SizedBox.shrink();
    }
    return ComposerPhotoStrip(
      onAttach: (photo) => stage(photo.bytes, photo.name),
      onBrowse: onBrowse,
      onClose: () =>
          ref.read(photoStripOpenProvider(channelId).notifier).state = false,
    );
  }
}

/// How many recent photos the strip loads before its closing tile.
const int _recentCount = 24;

const double _tileSize = 88;

class ComposerPhotoStrip extends ConsumerStatefulWidget {
  const ComposerPhotoStrip({
    super.key,
    required this.onAttach,
    required this.onBrowse,
    required this.onClose,
  });

  /// Hands one photo to the composer's own staging path.
  final Future<void> Function(PhotoOriginal photo) onAttach;

  /// Opens the full system picker, the way out of denied or limited access.
  final VoidCallback onBrowse;
  final VoidCallback onClose;

  @override
  ConsumerState<ComposerPhotoStrip> createState() => _ComposerPhotoStripState();
}

class _ComposerPhotoStripState extends ConsumerState<ComposerPhotoStrip> {
  PhotoAccess? _access;
  List<RecentPhoto> _photos = const [];
  bool _readFailed = false;

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
        photos = await library.recent(_recentCount);
      }
    } catch (_) {
      // A plugin that cannot read the library lands on the same way out as a refusal.
      access = PhotoAccess.denied;
    }
    if (!mounted) return;
    setState(() {
      _access = access;
      _photos = photos;
    });
  }

  Future<void> _manage() async {
    await ref.read(photoLibraryProvider)?.manageLimited();
    if (mounted) await _load();
  }

  Future<void> _attach(RecentPhoto photo) async {
    final original = await ref.read(photoLibraryProvider)?.original(photo.id);
    if (!mounted) return;
    if (original == null) {
      setState(() => _readFailed = true);
      return;
    }
    setState(() => _readFailed = false);
    await widget.onAttach(original);
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width >= kCompactWidth) {
      return const SizedBox.shrink();
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final access = _access;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaceSunken,
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(tokens, access),
              if (_readFailed)
                AppErrorState(
                  message: 'Could not read that photo.',
                  onDismiss: () => setState(() => _readFailed = false),
                ),
              if (access == null)
                const SizedBox(
                  height: _tileSize,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (access == PhotoAccess.denied)
                _denied(tokens)
              else
                _strip(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(AppTokens tokens, PhotoAccess? access) => Row(
    children: [
      Expanded(
        child: Text(
          access == PhotoAccess.limited
              ? 'Showing the photos you allowed'
              : 'Recent photos',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ),
      if (access == PhotoAccess.limited)
        AppButton(
          label: 'Allow more',
          variant: AppButtonVariant.ghost,
          onPressed: () => unawaited(_manage()),
        ),
      AppIconButton(
        icon: AppIcons.dismiss,
        semanticLabel: 'Close photo strip',
        onPressed: widget.onClose,
      ),
    ],
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

  Widget _strip() => SizedBox(
    height: _tileSize,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: _photos.length + 1,
      separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.s8),
      itemBuilder: (context, i) => i == _photos.length
          ? _AllPhotosTile(onTap: widget.onBrowse)
          : _PhotoTile(photo: _photos[i], onTap: () => _attach(_photos[i])),
    ),
  );
}

class _PhotoTile extends ConsumerStatefulWidget {
  const _PhotoTile({required this.photo, required this.onTap});
  final RecentPhoto photo;
  final VoidCallback onTap;

  @override
  ConsumerState<_PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends ConsumerState<_PhotoTile> {
  late final Future<Uint8List?>? _thumb = ref
      .read(photoLibraryProvider)
      ?.thumbnail(widget.photo.id, (_tileSize * 2).round());

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      label: 'Attach photo',
      child: GestureDetector(
        onTap: () {
          AppHaptics.selection();
          widget.onTap();
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.control),
          child: SizedBox.square(
            dimension: _tileSize,
            child: FutureBuilder<Uint8List?>(
              future: _thumb,
              builder: (context, snap) => snap.data == null
                  ? ColoredBox(color: tokens.surfaceRaised)
                  : Image.memory(snap.data!, fit: BoxFit.cover),
            ),
          ),
        ),
      ),
    );
  }
}

class _AllPhotosTile extends StatelessWidget {
  const _AllPhotosTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      label: 'All photos',
      child: GestureDetector(
        onTap: () {
          AppHaptics.selection();
          onTap();
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          child: SizedBox.square(
            dimension: _tileSize,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  AppIcons.image,
                  size: AppSizes.icon24,
                  color: tokens.textSecondary,
                ),
                const SizedBox(height: AppSpacing.s4),
                Text(
                  'All photos',
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
