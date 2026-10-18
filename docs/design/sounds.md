# Interface sounds

The app has 16 interface sounds and one iOS ringtone.
The owner picked them in two blind rounds from four designers' sets, so each sound keeps the idea of the designer whose version won.

## Levels

Notification cues (messages, mentions, join, leave, errors, the call ring) sit at -20 LUFS.
Cues for your own actions (sent, mute, deafen, joining or leaving a call, the ringback) sit at -26 LUFS.
Loudness is the loudest 200 ms window on a K-weighted scale, measured by `assets/audio/synth.py`.
Every file is 48 kHz, mono, 16-bit, peaks at or below -1 dBFS and starts and ends quiet.

## Key

The core of the palette is D major pentatonic: D, E, F#, A and B.
The theorist's cues use only those notes, plus one G# in `error`, which is meant to sound wrong.
The Kenney cues were retuned onto the same notes.
The call ring is the one exception: it is a groove in A minor pentatonic and is meant to stand apart from everything else.

## The sounds

| Sound | Designer | Idea |
| --- | --- | --- |
| `direct_message` | theorist | Rising fourth from the dominant onto the tonic, landing on a D and F# dyad: the one sound that closes on a chord, so it reads as warm and personal. |
| `mention` | theorist | Rising fifth from the tonic that ends on the open dominant, with a quiet echo: it asks for an answer instead of closing. |
| `group_message` | theorist | A single soft F#, stable but never a full stop, so a stream of them does not keep sounding like endings. |
| `message_received_in_view` | theorist | The group-message F# in felt, shorter and quieter: a tick, not a chime. |
| `message_sent` | theorist | One D with a fast lift from a whole step below: the message leaves your hand. |
| `error` | theorist | G# falls a tritone onto a dull D: the only chromatic tone, so the only sound that sours. |
| `member_join` | theorist | F#, A, D rising onto the tonic: someone arrives and the phrase comes home. |
| `mute_off` | theorist | A rising minor third, F# to A, in the bright bar timbre: switched on. |
| `member_leave` | dj | Three square plucks falling C, A, E with a darker, quicker filter: the mirror of join. |
| `call_ring` | dj | A 2.8 second syncopated saw arpeggio with a mid tok on the beat, hat ticks and a delay that wraps the loop seamlessly: it cuts through a room with no sub. |
| `mute_on` | game-ui | A hard click plus a short damped sine snapping down: a switch flicked to closed, with almost no ring. |
| `ringback` | Kenney | Two soft glass pings, down eight semitones, then silence to 3 seconds: calmer than the ring. |
| `self_join` | Kenney | The pack's rising sweep, retuned 25 cents so it ends on F#. |
| `self_leave` | Kenney | The falling sweep, same retune, so it starts on F#. |
| `deafen_on` | Kenney | A falling sweep, a few cents flat so it starts on D and its echoes sit on the key. |
| `deafen_off` | Kenney | A rising sweep retuned to end on D. |

`callkit_ringtone.wav` is not in the app.
It is the iOS CallKit ringtone: the `call_ring` loop three times with a 1.5 second pause between, since CallKit loops a file on its own.

## Regenerating

The WAVs are committed and `audio-ci` regenerates them and fails on any byte of drift.

```bash
pip install "numpy==2.4.6" "scipy==1.18.0"
python3 assets/audio/generate.py
cp assets/audio/notifications/*.wav client/packages/app/assets/audio/notifications/
rm client/packages/app/assets/audio/notifications/callkit_ringtone.wav
python3 -m unittest discover -s assets/audio -v
```

Each designer is one module under `assets/audio/palette/`, trimmed to the sounds that ship from it.
The client keeps a plain copy of the WAVs instead of a symlink, and `test_client_bundle.py` keeps the two identical.

## Credit

`ringback`, `self_join`, `self_leave`, `deafen_on` and `deafen_off` are edited from Kenney's Interface Sounds pack, https://kenney.nl/assets/interface-sounds, released under CC0 1.0.
The five source clips are committed as WAV in `assets/audio/palette/kenney/` with the pack's own license text.
