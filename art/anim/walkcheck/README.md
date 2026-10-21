# walkcheck: record and review locomotion from a Studio playtest

1. `python3 recv.py 8766` (outside the sandbox) writes POSTed recordings to `recs/<tag>.json`.
2. Studio: enable `HttpService.HttpEnabled` in Edit (turn it off again after), start Play, run `server_sink.luau` on the
   Server (a `WalkRecUp` RemoteEvent that posts to the sink), paste `rec.luau` on the Client and call
   `record(model, tag, seconds)` while driving the character (keys, `CombatTest` pivot/MoveTo for bots).
3. `blender --background --factory-startup --python render_rec.py -- recs/<tag>.json out N start span tag` renders
   block-figure frames from the side and back (world-fixed ground grid; `ORTHO=10` for bosses);
   `sheet.py out tag sheet.jpg "caption"` tiles them, `compare.py` stacks sheets, `metrics2.py tag:t0:t1` prints
   cadence, planted-foot slide, lift and hip bob.
