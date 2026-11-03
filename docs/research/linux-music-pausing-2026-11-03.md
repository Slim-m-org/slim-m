# Something pauses the owner's music during calls on Linux

Written 2026-11-03 after the report "something keeps pausing my music" (Fedora 44, KDE Plasma Wayland, PipeWire 1.6, WirePlumber 0.5.19, Spotify as a flatpak).
The cause was not found; this records what was ruled out so the next attempt does not repeat it.

## Method

- A private PipeWire, WirePlumber and pipewire-pulse under a separate `XDG_RUNTIME_DIR`, with ALSA, bluez, v4l2 and libcamera monitors disabled and a null sink and source.
- A stand-in MPRIS player on a private `dbus-run-session`, playing a tone through pulsesink with `media.role=music`, logging every Play, Pause, PlayPause and Stop call and any unexpected end of its stream.
- The owner's session was only read (`pactl list`), never written; his default sink was checked unchanged afterwards.

## Ruled out

- The client never touches MPRIS.
  `grep` finds no `org.mpris`, media key, `audio_service` or playerctl use in `client/` or `crates/` on Linux (the only now-playing code is the Windows SMTC channel).
  The installed 0.121.0 build was started in a nested `kwin_wayland --virtual` on the private bus: it claimed no MPRIS name and made no MPRIS call.
- Hold music, chimes and scene sounds (audioplayers, GStreamer playbin and pulsesink): the stand-in kept playing.
  Their streams carry no `media.role`, so WirePlumber's role policy has nothing to match.
- The share-audio mix (a `support.null-audio-sink` made through `pw-cli`, priority 0, nothing moved): the stand-in kept playing and the default sink did not change.
- Capture and playback with `media.role=phone` (what a communication stream looks like to WirePlumber): the stand-in kept playing, nothing was corked or ducked.
  WirePlumber 0.5 only ducks or corks through role loopback endpoints, which neither the stock config nor the owner's `wireplumber.conf.d` defines.
- Spotify account polling (`spotify_source.dart`) only reads playback state.

## Not covered

- A signed-in desktop call against a local LiveKit, so libwebrtc's own PulseAudio capture and playout open were not exercised through the app.
- The owner's real sinks (`sink_game`, `sink_music`, made by the Sink router) and the Arctis Nova Pro base station; the hardware profile may react to a microphone opening.
- Spotify pausing itself, for example when its sink node changes or an account-level Connect session takes over.

## Next step

Ask the owner for the trigger on a timestamp, then compare `dbus-monitor "interface='org.mpris.MediaPlayer2.Player'"` and `pw-mon` on his session at that moment to see whether a Pause call was sent or the stream was only stalled.
