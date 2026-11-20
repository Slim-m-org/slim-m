<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0128 - YouTube links play in the app, in place in the message; on desktop a playing video moves to a panel when its message leaves

Status: accepted, 2026-11-19.

## The ask

The owner, 2026-11-19: "is it possible to do an integrated youtube player on our youtube embeds?"
He picked the recommendation that followed: play in place where the platform can, and on desktop dock a player beside the chat that keeps playing while you scroll and switch channels.

Until now only the web build played a video in place (a `youtube-nocookie.com` iframe); every native platform opened the browser.

## Decision

- Every in-app player is YouTube's official embed player from `youtube-nocookie.com`, driven through its IFrame API.
  Nothing extracts a stream (yt-dlp, mpv): YouTube's terms forbid it.
- The player sits behind one small interface, `EmbeddedVideoPlayer` (load an id at a start time, play, pause, seek, position, and events for ready, playing, paused, buffering, ended and errors), so a later watch-together layer can drive any host the same way.
- Where a tapped video plays is a capability, never a layout choice (`desktop-vs-mobile.md`, the one rule):
  - The web build keeps its iframe in the message.
  - Phones play in the message, at the thumbnail's size, through the system webview (`webview_flutter`); YouTube's own fullscreen button takes it fullscreen, the one time a portrait-locked phone may turn (0058).
  - Linux and Windows dock it in a panel, because their native webviews float above the Flutter window and cannot be clipped or scrolled inside a message list.
  - Where no webview can load (no WebKitGTK at run time on Linux, the flatpak, no WebView2 runtime on Windows) a tap opens the browser, as before.
- On desktop the panel belongs to the shell, so it plays on across scrolling and channel switches until its close button is pressed.
  Width decides its shape: beside the chat in the third-pane slot at `kThreadPaneWidth` where `fitsThreadPane` allows, with the member roster moved under the player so a video never costs the roster; otherwise, or while a thread is docked there, a strip above the conversation.
  This is rule 8 (content the user chose to watch, kept once they leave where it lives); the panel is docked rather than floating because a native view cannot be dragged over Flutter content.
- The message whose video is in the panel shows "Playing in panel" over its thumbnail.
- A shared link's `t=` or `start=` becomes `video_start_ms` on the preview, so the player starts where the link asked.

## YouTube's rules the player follows

- The embed identifies itself with a referrer: each host serves its page from `https://top.npcserver.slimm`, the app id, since a webview with no referrer gets errors 152 and 153.
- One player plays at a time, app-wide.
- Nothing plays in the background: every player pauses when the app or window leaves the screen (minimised, hidden to the tray, a phone backgrounded).
  The desktop panel also pauses when it leaves the shell (the compact channel list, a fullscreen canvas) or a page or dialog covers it.
- The viewport is never smaller than 200 by 200: the panel's player is full-bleed, and every player keeps a 200 high floor.
- Nothing Flutter draws sits over a native player: it hides while a menu, drawer, dialog or page is over it.
- The player's top-level page never leaves the host page: a link, new window, redirect or script navigation off it opens the browser instead.

## Not done

- No watch-together sync yet; it builds on the interface above.
- No inline player inside a desktop message list; done since, see the 2026-11-20 amendment.
- The owner should review the App Store privacy answers and the privacy page: the embed loads Google content and can show ads once played.

## Amended 2026-11-20: desktop plays in the message too, and the panel is where it plays on

The owner, looking at "Playing in panel" on his Linux build: "why it is in panel instead of the actual embed player we already have?", then "do it so its like how discord does it inline".
A friend in the same chat called it "no intigrated player".

What changed:

- Linux and Windows play a tapped video in place in its message, at the thumbnail's size, like the web build and phones.
  The native webview is no longer laid over the window: each runner keeps it out of sight and hands its frames to Flutter as a texture, so the player clips, scrolls and sits under menus like any widget.
  - Linux keeps the one WebKitGTK view inside the window's overlay but allocated wholly left of the window, so it is mapped (WebKit treats a `GtkOffscreenWindow` as not on screen and will not play there) yet nothing real shows or reaches it.
    Each WebKit invalidation schedules a copy, at most one per 60 Hz frame, of `gtk_widget_draw` into a cairo image, swizzled into an `FlPixelBufferTexture`.
    Measured in Xvfb with no GPU (software decode and llvmpipe): 720p60 captured at about 57 frames a second, with the copy costing about 1 ms a frame; the UI thread spent about 16% of a core, Flutter's raster thread about 7% and WebKit's web process about 13%.
    A 360p30 video in the message captured 30 frames a second at about 12%, 8% and 9%.
  - Windows hosts WebView2 through a composition controller whose root visual is never shown; Windows.Graphics.Capture copies each frame of that visual into a shared D3D11 texture on Flutter's own adapter, which Flutter draws as a GPU surface texture.
    A visual's capture item keeps the size the visual had when the item was made, so each new size starts a new item; one made once at startup captured every frame at 16 by 16 pixels.
    WebView2 refuses fullscreen to a page that is not focused, and a press sent to a hosted visual blurs it, so the runner focuses the page through the DevTools protocol (`Page.bringToFront`) before each release; Win32 focus, and so the keyboard, stays with Flutter.
    Measured in the win11 VM (8 vCPUs, no GPU, WARP): 720p60 fullscreen took about 5 to 9% of one core in the app, about 4.5% in WebView2's processes and about 12% in dwm; the same video in the message took about 2% and 5%.
    Visual capture needs Windows 10 1903 or newer; without it, as without the WebView2 runtime, the probe says no and a video opens in the browser.
    `flutter_inappwebview_windows` was not used: the app-facing package still breaks Linux builds, and the runner's own host already carries the referrer, navigation and permission rules above.
- The pointer is forwarded from Flutter to the page (enter, move, primary press and release, leave), so YouTube's own controls, seek bar and double click work.
  The scroll wheel scrolls the conversation, as it does over an iframe that does not scroll.
  Keys are never forwarded, and the Linux view cannot take GTK focus (the window hands it straight back if WebKit ever forces it), so a click in the player never leaves a text field deaf.
- YouTube's fullscreen button covers the window with a Flutter route showing the same texture, the page sized to it; Escape or the page leaving fullscreen pops it.
- Where a video plays once its message leaves the screen: a playing video moves to the existing panel and plays on there, the way Discord pops one out; a paused one closes.
  A message leaves when it scrolls wholly out of its list's sight or is unmounted, as by a channel switch.
  The panel stays docked rather than floating, since it already has a place at every width (rule 8 of `desktop-vs-mobile.md`) and covers nothing.
  Its message shows "Playing in panel" over the thumbnail, and a tap there brings the video back into the message without starting over.
- The player is still one per app: the panel and the message show the same texture of the same webview, so a move never reloads.
- Nothing Flutter draws needs to hide the player any more, so menus, drawers and dialogs no longer blank it; a page that covers it (TickerMode off) still counts as out of sight, and with no view showing it the video pauses.
- The browser fallback is unchanged: no WebKitGTK 2.40 at run time, the flatpak, or no WebView2 runtime opens the link in the browser.

Verified on Windows in the win11 VM only: playing in the message, YouTube's own controls (pause, seek, settings), scroll clipping, the move to the panel and back, fullscreen from YouTube's button and Escape out of it, typing in the composer and search after a click in the player, and the pause when the window is minimised.
Not verified on this change: the Windows build on real hardware with a GPU, and the Linux path on a GPU-backed WebKit, where WebKit's DMA-BUF renderer paints through `gdk_cairo_draw_from_gl` into the same image surface.