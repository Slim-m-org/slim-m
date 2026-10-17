// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tapped image opened over the app, paging through every image on its
/// message. The tapped page gets the bytes already on screen so it never
/// shows a spinner; siblings load their own. Only the tapped page carries
/// the Hero tag, minted per thumbnail because one content-addressed image
/// can appear on several messages. The backdrop is black in both themes,
/// and a transparent [Material] gives the root-navigator route text styles.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/attachment_bytes.dart';
import 'fullscreen_image_actions.dart';
import 'fullscreen_image_page.dart';
import 'image_actions_menu.dart';
import 'message_row_parts.dart';

/// How large the floating viewer is allowed to get on a desktop window.
const double kViewerMaxWidth = 1100;
const double kViewerMaxHeight = 820;

/// Opens [images] fullscreen at [index], with that page's [bytes] already in
/// hand. Non-opaque so the conversation behind stays visible through the fade
/// rather than the route cutting to black.
Future<void> showFullscreenImage(
  BuildContext context, {
  required List<api.Attachment> images,
  required int index,
  required Uint8List bytes,
  Object? heroTag,
}) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: AppMotion.reduced(
        context,
        const Duration(milliseconds: 160),
      ),
      reverseTransitionDuration: AppMotion.reduced(
        context,
        const Duration(milliseconds: 120),
      ),
      pageBuilder: (_, animation, _) => FadeTransition(
        opacity: animation,
        child: FullscreenImageViewer(
          images: images,
          index: index,
          bytes: bytes,
          heroTag: heroTag,
        ),
      ),
    ),
  );
}

class FullscreenImageViewer extends ConsumerStatefulWidget {
  const FullscreenImageViewer({
    super.key,
    required this.images,
    required this.index,
    required this.bytes,
    this.heroTag,
  });

  /// Every image on the message, in the order the message shows them.
  final List<api.Attachment> images;

  /// Which of [images] was tapped, and so which page opens first and which
  /// one [bytes] belongs to.
  final int index;

  /// The tapped image's bytes, already fetched by the row that opened this.
  final Uint8List bytes;

  /// The tapped thumbnail's own identity tag, or null for a caller with no
  /// thumbnail to fly from; see the library doc for why never a shared id.
  final Object? heroTag;

  @override
  ConsumerState<FullscreenImageViewer> createState() =>
      _FullscreenImageViewerState();
}

class _FullscreenImageViewerState extends ConsumerState<FullscreenImageViewer> {
  late final PageController _pages = PageController(initialPage: widget.index);
  late int _current = widget.index;
  bool _zoomed = false;
  String? _exportFailure;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _pages.dispose();
    super.dispose();
  }

  void _close() {
    Navigator.of(context).maybePop();
  }

  void _step(int by) {
    final target = _current + by;
    if (target < 0 || target >= widget.images.length) return;
    final duration = AppMotion.reduced(
      context,
      const Duration(milliseconds: 180),
    );
    // A zero-length animateToPage never moves the page; reduced motion jumps.
    if (duration == Duration.zero) {
      _pages.jumpToPage(target);
      return;
    }
    _pages.animateToPage(
      target,
      duration: duration,
      curve: Curves.easeOutCubic,
    );
  }

  /// Arrows page and Escape closes, for a desktop window with no swipe.
  ///
  /// A hardware handler rather than a focus node's `onKeyEvent`: on web the
  /// browser moves focus to the semantics layer once the route is open, and a
  /// key then never reaches the viewer's own node.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    // A dialog opened over the viewer owns the keyboard until it closes.
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _step(1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _step(-1);
    } else {
      return false;
    }
    return true;
  }

  /// One page. The tapped image already has its bytes and must never flash a
  /// spinner; a sibling has never been fetched, so it shows the two states the
  /// tapped page cannot reach.
  Widget _page(int index) {
    final image = widget.images[index];
    if (index == widget.index) {
      return FullscreenImagePage(
        filename: image.filename,
        bytes: widget.bytes,
        heroTag: widget.heroTag,
        onDismiss: _close,
        onZoomChanged: _onZoomChanged,
      );
    }
    return ref
        .watch(attachmentBytesProvider(image.id))
        .when(
          loading: () => const Center(child: AttachmentPlaceholder()),
          error: (_, _) => FullscreenLoadFailure(
            filename: image.filename,
            onRetry: () => ref.invalidate(attachmentBytesProvider(image.id)),
          ),
          data: (bytes) => FullscreenImagePage(
            filename: image.filename,
            bytes: bytes,
            onDismiss: _close,
            onZoomChanged: _onZoomChanged,
          ),
        );
  }

  Future<Uint8List> _currentBytes() {
    if (_current == widget.index) return Future.value(widget.bytes);
    return ref.read(attachmentBytesProvider(widget.images[_current].id).future);
  }

  void _onZoomChanged(bool zoomed) => setState(() => _zoomed = zoomed);

  @override
  Widget build(BuildContext context) {
    // A phone gives the image the whole window, which is the point of opening
    // it. A desktop window has room to keep the app visible around it, so the
    // image floats in a panel and a click beside it puts the image away.
    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;
    return Theme(
      data: buildTheme(Brightness.dark, AppTokens.dark),
      // Material ancestor for Text/Icon; see this file's library doc.
      child: Material(
        type: MaterialType.transparency,
        child: _Backdrop(
          compact: compact,
          onDismiss: _close,
          child: SafeArea(
            child: Focus(
              autofocus: true,
              child: Column(
                children: [
                  _ViewerHeader(
                    filename: widget.images[_current].filename,
                    counter: widget.images.length > 1
                        ? '${_current + 1} of ${widget.images.length}'
                        : null,
                    onClose: _close,
                    actions: ImageExportActions(
                      key: ValueKey(widget.images[_current].id),
                      image: widget.images[_current],
                      loadBytes: _currentBytes,
                      onFailure: (message) =>
                          setState(() => _exportFailure = message),
                    ),
                  ),
                  if (_exportFailure case final message?)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s12,
                      ),
                      child: AppErrorState(
                        message: message,
                        onDismiss: () => setState(() => _exportFailure = null),
                      ),
                    ),
                  Expanded(
                    child: ImageActionsMenuRegion(
                      image: widget.images[_current],
                      loadBytes: _currentBytes,
                      onFailure: (message) =>
                          setState(() => _exportFailure = message),
                      child: PageView.builder(
                        controller: _pages,
                        // Zoomed in, a horizontal drag is a pan across this image, never a turn to the next one.
                        physics: _zoomed
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        itemCount: widget.images.length,
                        onPageChanged: (index) => setState(() {
                          _current = index;
                          _exportFailure = null;
                        }),
                        itemBuilder: (_, index) => _page(index),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewerHeader extends StatelessWidget {
  const _ViewerHeader({
    required this.filename,
    required this.counter,
    required this.onClose,
    required this.actions,
  });

  final String filename;

  /// Share and Save for the image on screen, left of the close control.
  final Widget actions;

  /// "2 of 5", or null when the message carries only this one image and there
  /// is nothing to count.
  final String? counter;

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: AppSpacing.s4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              filename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.ui.copyWith(color: tokens.textSecondary),
            ),
          ),
          if (counter case final counter?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
              child: Text(
                counter,
                style: AppText.label.copyWith(color: tokens.textSecondary),
              ),
            ),
          actions,
          AppIconButton(
            icon: AppIcons.dismiss,
            semanticLabel: 'Close image',
            size: AppIconButtonSize.touch,
            touch: true,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// The dark field the image sits on, and what a click on it means.
///
/// On a phone it is the window and a click on it does nothing, because there
/// is no "outside" to click: the drag gesture is how the image is dismissed.
/// On a desktop window it is a scrim around a floating panel, and clicking it
/// closes the viewer the way clicking beside any modal does.
class _Backdrop extends StatelessWidget {
  const _Backdrop({
    required this.compact,
    required this.onDismiss,
    required this.child,
  });

  final bool compact;
  final VoidCallback onDismiss;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    if (compact) {
      return ColoredBox(
        color: Colors.black.withValues(alpha: 0.94),
        child: child,
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.72)),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kViewerMaxWidth,
              maxHeight: kViewerMaxHeight,
            ),
            // Swallows the taps that land on the panel, so only a click that
            // reaches the scrim behind it counts as clicking outside.
            child: GestureDetector(
              onTap: () {},
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.card),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.94),
                    border: Border.all(color: tokens.borderSubtle),
                    borderRadius: BorderRadius.circular(AppRadii.card),
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
