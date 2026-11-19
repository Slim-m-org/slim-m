<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0128 - YouTube links play in the app: in place on phones, in a docked panel on desktop

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
- The viewport is never smaller than 200 by 200: the panel's player is full-bleed, and every player keeps a 200 high floor.
- Nothing Flutter draws sits over a native player: it hides while a menu, dialog or page is over it.

## Not done

- No watch-together sync yet; it builds on the interface above.
- No inline player inside a desktop message list.
  `flutter_inappwebview_windows` renders into a Flutter texture and could do it on Windows, but its app-facing package adds a Linux implementation that breaks every Linux build, so it stays the fallback if this is ever wanted.
- The owner should review the App Store privacy answers and the privacy page: the embed loads Google content and can show ads once played.
