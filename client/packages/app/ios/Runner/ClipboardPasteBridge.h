// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs the swizzle documented in ClipboardPasteBridge.m, which makes
/// `FlutterTextInputView`'s own `canPerformAction:`/`paste:` accept an image
/// rather than only a string.
///
/// `onImage` is invoked on the main queue with the pasteboard's image as PNG
/// data. The pasteboard itself is read synchronously, from inside iOS's own
/// dispatch of the native `paste:` action; see the .m file for why that
/// ordering is load-bearing.
///
/// Returns whether the swizzle installed, never whether it is actually
/// reachable. Confirmed on a real device 2026-08-01 that those differ: on a
/// plain Material `TextField`, Flutter's `SystemContextMenu` decides Paste's
/// presence in Dart before any native call, so `canPerformAction:` here is
/// never consulted regardless of this return value - see the .m file's doc
/// comment. A caller must still treat NO as "the swizzle itself did not
/// install" (a missing class or selector, failing safe rather than
/// crashing), but must never treat YES as "Paste now works".
BOOL SlimmInstallClipboardPasteBridge(void (^onImage)(NSData *pngData));

NS_ASSUME_NONNULL_END
