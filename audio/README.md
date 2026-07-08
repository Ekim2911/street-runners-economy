# Mission audio

Drop `.mp3` (or `.ogg`) clips here and they're served at
`https://<server>/audio/<filename>` and streamed in-game by the Lua via
`ui.MediaPlayer` — no per-player install.

Filenames the script looks for (see `CONFIG.audio` in `street_runners_missions.lua`):

- `delivery_start.mp3`  — plays when a smuggling run begins (the "briefing")
- `delivery_pickup.mp3` — plays when you grab the cargo
- `delivery_wanted.mp3` — plays when the cops get on you (heat maxes)
- `delivery_done.mp3`   — plays on a clean delivery
- `delivery_busted.mp3` — plays when you get busted

Any missing file is simply skipped. Keep clips short and reasonably small
(a few hundred KB) so they start quickly over the stream.
