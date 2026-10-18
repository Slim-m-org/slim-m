# Lounge music sources

`generate.py` (with `dsp.py`) renders the solo-call music made for slim-m into `wav/`, deterministically, using numpy and scipy only.
Only `wav/electronic.wav` ("Quiet Pulse") ships; it is encoded to `client/packages/app/assets/audio/music/electronic.mp3` with `ffmpeg -i wav/electronic.wav -ar 44100 -b:a 96k electronic.mp3`.
The script also renders a lofi track that was auditioned and not picked.
