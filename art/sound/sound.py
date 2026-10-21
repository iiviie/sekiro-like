#!/usr/bin/env python3
"""LAST BLADE sound pipeline: ElevenLabs -> trim/loop/normalise -> banks -> Roblox -> AudioIds.luau.

Cues live in art/sound/cues.json (the plan: research_notes/sound/sound_plan.md). Python 3.9+,
standard library only, plus ffmpeg/ffprobe on PATH.

    python3 sound.py plan                     # counts, cost estimate (add --markdown for the plan tables)
    python3 sound.py check                    # every cue has a player in client/Audio or client/UI
    python3 sound.py generate [--only ids] [--priority P0,P1] [--force] [--regen-changed]
    python3 sound.py process                  # raw -> normalised takes (trim, fades, loops, slices)
    python3 sound.py bank                     # takes -> out/upload/*.flac (+ out/preview/*.mp3)
    python3 sound.py upload [--user-id N | --group-id N] [--bulk]
    python3 sound.py link FILE=ASSETID ...    # after a Studio bulk import (or --csv file.csv)
    python3 sound.py ids                      # rewrite src/shared/AudioIds.luau from ids.json
    python3 sound.py all [...]                # generate, process, bank, upload (or import folder)
    add --dry-run to any of them: no network; synthetic audio and fake ids under art/sound/.dryrun/

Keys: ElevenLabs ~/.config/elevenlabs/key, Roblox Open Cloud ~/.config/roblox/opencloud_key
(API key with Assets read+write), creator ~/.config/roblox/creator ("user:123" or "group:456")
or --user-id/--group-id. Keys are never printed.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import datetime
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
CUES = HERE / "cues.json"
AUDIO_LUAU = REPO / "src" / "client" / "Audio.luau"
UI_LUAU = REPO / "src" / "client" / "UI.luau"
AUDIO_IDS = REPO / "src" / "shared" / "AudioIds.luau"

ELEVEN_KEY = Path.home() / ".config" / "elevenlabs" / "key"
ROBLOX_KEY = Path.home() / ".config" / "roblox" / "opencloud_key"
ROBLOX_CREATOR = Path.home() / ".config" / "roblox" / "creator"

ELEVEN = "https://api.elevenlabs.io"
ROBLOX_ASSETS = "https://apis.roblox.com/assets/v1"
SR = 44100
SFX_CREDITS_PER_SECOND = 40  # ElevenLabs docs: sound effects with a set duration
UPLOAD_LIMIT = 19_500_000  # Open Cloud: 20 MB per create request


# --------------------------------------------------------------------------------------------
# Setup


class Ctx:
    def __init__(self, args):
        self.args = args
        self.dry = bool(getattr(args, "dry_run", False))
        base = HERE / ".dryrun" if self.dry else HERE
        self.raw = base / "raw"
        self.work = base / "work"
        self.out = base / "out"
        self.ids_json = base / "ids.json"
        self.audio_ids = (base / "AudioIds.luau") if self.dry else AUDIO_IDS
        doc = json.loads(CUES.read_text())
        self.defaults = doc["defaults"]
        self.banks = doc["banks"]
        self.cues = doc["cues"]
        self.by_id = {c["id"]: c for c in self.cues}

    def selected(self):
        a = self.args
        only = set(filter(None, (getattr(a, "only", "") or "").split(",")))
        pri = set(filter(None, (getattr(a, "priority", "") or "").split(",")))
        out = []
        for c in self.cues:
            if only and c["id"] not in only and c.get("bank") not in only:
                continue
            if pri and c["priority"] not in pri:
                continue
            out.append(c)
        return out


def log(*parts):
    print(*parts, flush=True)


def need_ffmpeg():
    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            sys.exit(f"{tool} not found on PATH (brew install ffmpeg)")


def ff(*args, capture=False):
    cmd = ["ffmpeg", "-hide_banner", "-nostdin", "-y", "-loglevel", "info" if capture else "error", *map(str, args)]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        raise RuntimeError("ffmpeg failed: " + " ".join(cmd) + "\n" + p.stderr[-2000:])
    return p.stderr


def duration_of(path: Path) -> float:
    p = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(path)],
        stdout=subprocess.PIPE, text=True, check=True)
    return float(p.stdout.strip() or 0)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_key(path: Path, what: str) -> str:
    if not path.exists():
        sys.exit(f"{what} key file missing: {path}")
    key = path.read_text().strip()
    if not key:
        sys.exit(f"{what} key file is empty: {path}")
    return key


# --------------------------------------------------------------------------------------------
# plan / check


def cue_seconds(c) -> float:
    return float(c.get("duration") or 1.0) * int(c.get("takes", 1))


def cmd_plan(ctx: Ctx):
    sfx = [c for c in ctx.cues if c["kind"] in ("sfx", "ambience")]
    mus = [c for c in ctx.cues if c["kind"] in ("music", "stinger")]
    gens = sum(int(c.get("takes", 1)) for c in ctx.cues)
    sfx_s = sum(cue_seconds(c) for c in sfx)
    mus_s = sum(cue_seconds(c) for c in mus)
    banks = sorted({c["bank"] for c in ctx.cues if c.get("bank")})
    singles = [c["id"] for c in ctx.cues if not c.get("bank")]
    log(f"{len(ctx.cues)} cues, {gens} generations")
    for p in ("P0", "P1", "P2"):
        cs = [c for c in ctx.cues if c["priority"] == p]
        log(f"  {p}: {len(cs)} cues, {sum(int(c.get('takes', 1)) for c in cs)} generations, "
            f"sfx {sum(cue_seconds(c) for c in cs if c in sfx):.0f} s, music {sum(cue_seconds(c) for c in cs if c in mus) / 60:.1f} min")
    log(f"sound effects: {sum(int(c.get('takes', 1)) for c in sfx)} generations, {sfx_s:.0f} s "
        f"~ {sfx_s * SFX_CREDITS_PER_SECOND:,.0f} credits at {SFX_CREDITS_PER_SECOND}/s")
    log(f"music + stingers: {sum(int(c.get('takes', 1)) for c in mus)} generations, {mus_s / 60:.1f} min")
    log(f"Roblox uploads: {len(banks)} banks ({', '.join(banks)}) + {len(singles)} loops = {len(banks) + len(singles)} assets")
    if getattr(ctx.args, "markdown", False):
        log()
        log(markdown(ctx))


def markdown(ctx: Ctx) -> str:
    rows = []
    groups = [
        ("Combat (3D, bank `combat`)", lambda c: c.get("bank") == "combat"),
        ("Footsteps and landings (3D, bank `foot`)", lambda c: c.get("bank") == "foot"),
        ("UI (2D, bank `ui`)", lambda c: c.get("bank") == "ui"),
        ("Finishers and the Victory cry (3D, bank `fx`)", lambda c: c.get("bank") == "fx"),
        ("Intros (3D, bank `intro`)", lambda c: c.get("bank") == "intro"),
        ("Stingers (2D, Music group, bank `sting`, Music API)", lambda c: c.get("bank") == "sting"),
        ("Ambience loops (SFX API `loop: true`)", lambda c: c["kind"] == "ambience"),
    ]
    for title, test in groups:
        rows.append(f"#### {title}\n")
        rows.append("| id | pri | moment | len s | takes | loudness | placeholder today | prompt |")
        rows.append("|---|---|---|---|---|---|---|---|")
        for c in ctx.cues:
            if not test(c):
                continue
            bank = ctx.banks.get(c.get("bank", ""), {})
            norm = c.get("norm", bank.get("norm", "lufs"))
            target = c.get("target", bank.get("target", -16))
            loud = f"{target:g} dBTP peak" if norm == "peak" else f"{target:g} LUFS"
            takes = c.get("takes", 1)
            if c.get("slice"):
                takes = f"1 gen sliced to {c['slice']['keep']}"
            length = c.get("max_len") or (c.get("slice") or {}).get("max_len") or c.get("duration")
            rows.append(f"| `{c['id']}` | {c['priority']} | {c['moment']} | {length:g} | {takes} | {loud} | "
                        f"{c.get('placeholder') or 'none (silent)'} | {c['prompt']} |")
        rows.append("")
    rows.append("#### Music beds (Music API, instrumental, crossfade-looped)\n")
    rows.append("| id | pri | moment | length s | BPM | mood | instruments | loop x-fade s | prompt |")
    rows.append("|---|---|---|---|---|---|---|---|---|")
    for c in ctx.cues:
        if c["kind"] == "music":
            rows.append(f"| `{c['id']}` | {c['priority']} | {c['moment']} | {c['duration']:g} | {c['bpm']} | "
                        f"{c['mood']} | {c['instruments']} | {c['xfade']:g} | {c['prompt']} |")
    return "\n".join(rows)


def luau_keys(path: Path, start: str) -> set:
    text = path.read_text()
    i = text.index(start)
    block = text[i:text.index("\n}\n", i)]
    return set(re.findall(r"^\t(\w+) = \{", block, re.M))


def cmd_check(ctx: Ctx):
    defs = luau_keys(AUDIO_LUAU, "local DEFS")
    ui = {"UI" + k for k in luau_keys(UI_LUAU, "local SOUNDS")}
    played = defs | ui
    ok = True
    for c in ctx.cues:
        if c["id"] not in played:
            ok = False
            log(f"cue {c['id']}: nothing plays it (no DEFS entry in client/Audio, no UI.sound name)")
    ids = set(ctx.by_id)
    for k in sorted(defs - ids):
        text = AUDIO_LUAU.read_text()
        line = next((ln for ln in text.splitlines() if re.match(rf"^\t{k} = \{{", ln)), "")
        if "ph =" not in line and "fallback" not in line and "skipIf" not in line:
            log(f"Audio def {k}: generated-only but not in cues.json (it can never sound)")
            ok = False
    for c in ctx.cues:
        if c["kind"] in ("sfx", "stinger") and not c.get("bank"):
            log(f"cue {c['id']}: one-shot without a bank")
            ok = False
        if c.get("bank") and c["bank"] not in ctx.banks:
            log(f"cue {c['id']}: unknown bank {c['bank']}")
            ok = False
    log("check: ok" if ok else "check: problems above")
    return ok


# --------------------------------------------------------------------------------------------
# generate


def prompt_of(ctx: Ctx, c) -> str:
    suffix = ctx.defaults["music_suffix"] if c["kind"] in ("music", "stinger") else ctx.defaults["sfx_suffix"]
    return f"{c['prompt']}. {suffix}"


def request_of(ctx: Ctx, c, take: int):
    """(url, body) for one generation."""
    d = ctx.defaults
    if c["kind"] in ("music", "stinger"):
        body = {
            "prompt": prompt_of(ctx, c),
            "music_length_ms": max(3000, int(round(float(c["duration"]) * 1000))),
            "model_id": getattr(ctx.args, "music_model", None) or d["music_model"],
            "force_instrumental": True,
        }
        return f"{ELEVEN}/v1/music?output_format={d['music_output_format']}", body
    body = {
        "text": prompt_of(ctx, c),
        "duration_seconds": min(30.0, max(0.5, float(c.get("duration") or 1.0))),
        "prompt_influence": float(c.get("influence", d["prompt_influence"])),
        "model_id": d["sfx_model"],
    }
    if c.get("loop") == "native":
        body["loop"] = True
    return f"{ELEVEN}/v1/sound-generation?output_format={d['sfx_output_format']}", body


def raw_path(ctx: Ctx, c, take: int) -> Path:
    return ctx.raw / c["id"] / f"{c['id']}_{take:02d}.mp3"


def body_hash(body) -> str:
    return hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()[:16]


def http(method, url, headers, data=None, timeout=300):
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, dict(r.headers), r.read()


def eleven_call(key: str, url: str, body: dict) -> bytes:
    data = json.dumps(body).encode()
    headers = {"xi-api-key": key, "Content-Type": "application/json", "Accept": "audio/mpeg"}
    for attempt in range(5):
        try:
            _, _, payload = http("POST", url, headers, data)
            return payload
        except urllib.error.HTTPError as e:
            detail = e.read()[:600].decode("utf-8", "replace")
            if e.code in (429, 500, 502, 503, 504) and attempt < 4:
                wait = 3 * 2 ** attempt
                log(f"    {e.code}, retrying in {wait} s")
                time.sleep(wait)
                continue
            raise RuntimeError(f"ElevenLabs {e.code}: {detail}") from None
        except urllib.error.URLError as e:
            if attempt < 4:
                time.sleep(3 * 2 ** attempt)
                continue
            raise RuntimeError(f"ElevenLabs unreachable: {e}") from None
    raise RuntimeError("unreachable")


def synth(c, path: Path, seconds: float):
    """Dry run: stand-in audio shaped like the real thing (with silence to trim, gaps to slice)."""
    d = max(0.5, seconds)
    if c.get("slice"):
        n = c["slice"]["keep"]
        period = d / (n + 0.5)
        expr = f"0.6*sin(2*PI*(180+40*floor(t/{period:.4f}))*t)*exp(-25*mod(t,{period:.4f}))*lt(mod(t,{period:.4f}),0.22)"
        src = ["-f", "lavfi", "-i", f"aevalsrc='{expr}':s={SR}:d={d}"]
    elif c["kind"] == "ambience":
        src = ["-f", "lavfi", "-i", f"anoisesrc=c=brown:a=0.3:d={d}:r={SR}"]
    elif c["kind"] in ("music", "stinger"):
        src = ["-f", "lavfi", "-i", f"aevalsrc='0.25*sin(2*PI*220*t)+0.2*sin(2*PI*277*t)+0.15*sin(2*PI*330*t)*(0.5+0.5*sin(2*PI*t))':s={SR}:d={d}"]
    else:
        body = max(0.15, d - 0.3)
        expr = f"if(lt(t,0.08),0,0.7*(random(0)*2-1)*exp(-6*(t-0.08)/{body:.3f}))*lt(t,{0.08 + body:.3f})"
        src = ["-f", "lavfi", "-i", f"aevalsrc='{expr}':s={SR}:d={d}"]
    ff(*src, "-ac", "2", "-c:a", "libmp3lame", "-b:a", "128k", path)


def cmd_generate(ctx: Ctx):
    need_ffmpeg()
    key = None if ctx.dry else read_key(ELEVEN_KEY, "ElevenLabs")
    jobs = []
    for c in ctx.selected():
        for take in range(1, int(c.get("takes", 1)) + 1):
            url, body = request_of(ctx, c, take)
            path = raw_path(ctx, c, take)
            meta = path.with_suffix(".json")
            h = body_hash(body)
            if path.exists() and not ctx.args.force:
                old = json.loads(meta.read_text()).get("hash") if meta.exists() else None
                if old == h or not ctx.args.regen_changed:
                    if old != h:
                        log(f"  {path.name}: prompt changed since it was made; kept (--regen-changed to remake)")
                    continue
            jobs.append((c, take, url, body, path, meta, h))
    if not jobs:
        log("generate: nothing to do")
        return
    log(f"generate: {len(jobs)} generations{' (dry run, synthetic)' if ctx.dry else ''}")

    def run(job):
        c, take, url, body, path, meta, h = job
        path.parent.mkdir(parents=True, exist_ok=True)
        if ctx.dry:
            seconds = (body.get("music_length_ms") or 0) / 1000 or body.get("duration_seconds") or 1
            synth(c, path, seconds)
            model = body.get("model_id")
        else:
            try:
                audio = eleven_call(key, url, body)
                model = body.get("model_id")
            except RuntimeError as e:
                # music_v2_5 not on this plan / not accepting a field: fall back to music_v1 once
                if "model_id" in body and str(body["model_id"]).startswith("music_v2"):
                    log(f"    {path.name}: {e}; retrying with music_v1")
                    body = dict(body, model_id="music_v1")
                    audio = eleven_call(key, url, body)
                    model = "music_v1"
                else:
                    raise
            tmp = path.with_suffix(".part")
            tmp.write_bytes(audio)
            tmp.replace(path)
        meta.write_text(json.dumps({
            "id": c["id"], "take": take, "hash": h, "model": model, "url": url.split("?")[0],
            "request": body, "made": datetime.datetime.now().isoformat(timespec="seconds"),
            "dry_run": ctx.dry,
        }, indent=1))
        return path

    failed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, ctx.args.jobs)) as pool:
        futures = {pool.submit(run, j): j for j in jobs}
        for f in concurrent.futures.as_completed(futures):
            j = futures[f]
            try:
                log(f"  ok  {f.result().relative_to(ctx.raw)}")
            except Exception as e:  # keep going: one bad prompt shouldn't stop the batch
                failed += 1
                log(f"  ERR {j[0]['id']}_{j[1]:02d}: {e}")
    if failed:
        sys.exit(f"generate: {failed} failed")


# --------------------------------------------------------------------------------------------
# process


def loudness(path: Path):
    """(integrated LUFS or None, true peak dBTP) via loudnorm's measurement pass."""
    err = ff("-i", path, "-af", "loudnorm=print_format=json", "-f", "null", "-", capture=True)
    m = re.search(r"\{[^{}]*\"input_i\"[^{}]*\}", err, re.S)
    if not m:
        return None, -1.0
    data = json.loads(m.group(0))

    def num(v):
        try:
            x = float(v)
            return x if math.isfinite(x) else None
        except ValueError:
            return None
    return num(data.get("input_i")), (num(data.get("input_tp")) or -60.0)


def settings_of(ctx: Ctx, c):
    bank = ctx.banks.get(c.get("bank", ""), {})
    channels = int(c.get("channels", bank.get("channels", 2)))
    norm = c.get("norm", bank.get("norm", "lufs"))
    target = float(c.get("target", bank.get("target", -16)))
    return channels, norm, target


def silences(path: Path, threshold_db: float, min_gap: float):
    err = ff("-i", path, "-af", f"silencedetect=noise={threshold_db}dB:d={min_gap}", "-f", "null", "-", capture=True)
    starts = [float(x) for x in re.findall(r"silence_start: (-?[\d.]+)", err)]
    ends = [float(x) for x in re.findall(r"silence_end: (-?[\d.]+)", err)]
    return starts, ends


def sound_spans(path: Path, threshold_db: float, min_gap: float):
    """Non-silent spans of a file (for slicing a run of footsteps into takes)."""
    total = duration_of(path)
    starts, ends = silences(path, threshold_db, min_gap)
    spans, cursor = [], 0.0
    for i, s in enumerate(starts):
        if s - cursor > 0.03:
            spans.append((max(0.0, cursor), s))
        cursor = ends[i] if i < len(ends) else total
    if total - cursor > 0.03:
        spans.append((cursor, total))
    return spans


def finish(ctx: Ctx, c, src: Path, dst: Path, filters: list, channels: int, norm: str, target: float):
    """Apply `filters`, then one gain stage to the loudness target (never above -1 dBTP)."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    mid = dst.with_suffix(".pre.wav")
    chain = ",".join(filters) if filters else "anull"
    ff("-i", src, "-af", chain, "-ac", channels, "-ar", SR, "-c:a", "pcm_f32le", mid)
    length = duration_of(mid)
    lufs, tp = loudness(mid)
    if norm == "peak" or lufs is None or length < 1.0:
        peak_target = target if norm == "peak" else -1.0
        gain = peak_target - tp
    else:
        gain = min(target - lufs, -1.0 - tp)
    ff("-i", mid, "-af", f"volume={gain:.2f}dB", "-ac", channels, "-ar", SR, "-c:a", "pcm_s16le", dst)
    mid.unlink()
    after, tp_after = loudness(dst)
    return {"file": str(dst.relative_to(ctx.work)), "seconds": round(duration_of(dst), 3),
            "gain_db": round(gain, 2), "lufs": None if after is None else round(after, 1), "peak_dbtp": round(tp_after, 1)}


def one_shot_filters(c, length_cap: float | None):
    f = [
        "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.004",
        "areverse", "silenceremove=start_periods=1:start_threshold=-55dB:start_silence=0.02", "areverse",
    ]
    if length_cap:
        f.append(f"atrim=0:{length_cap}")
    f.append("afade=t=in:d=0.003")
    return f


def tail_fade(path: Path, seconds: float) -> str:
    length = duration_of(path)
    d = min(seconds, max(0.01, length * 0.25))
    return f"afade=t=out:st={max(0.0, length - d):.4f}:d={d:.4f}"


def process_cue(ctx: Ctx, c):
    channels, norm, target = settings_of(ctx, c)
    takes = sorted((ctx.raw / c["id"]).glob(f"{c['id']}_*.mp3"))
    if not takes:
        return None
    out_dir = ctx.work / "takes" / c["id"]
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)
    results = []
    n = 0
    for raw in takes:
        if c.get("slice"):
            s = c["slice"]
            decoded = out_dir / (raw.stem + ".decoded.wav")
            ff("-i", raw, "-ac", channels, "-ar", SR, "-c:a", "pcm_f32le", decoded)
            spans = sound_spans(decoded, s.get("threshold_db", -38), s.get("min_gap", 0.12))
            spans = [sp for sp in spans if sp[1] - sp[0] >= 0.05][: s["keep"]]
            if not spans:
                log(f"  {raw.name}: nothing to slice (kept whole)")
                spans = [(0.0, duration_of(decoded))]
            for a, b in spans:
                n += 1
                cut = out_dir / f"{c['id']}_{n:02d}.cut.wav"
                start = max(0.0, a - 0.01)
                end = min(b + 0.04, start + s.get("max_len", 0.5))
                ff("-i", decoded, "-af", f"atrim={start:.4f}:{end:.4f},asetpts=PTS-STARTPTS", "-c:a", "pcm_f32le", cut)
                dst = out_dir / f"{c['id']}_{n:02d}.wav"
                results.append(finish(ctx, c, cut, dst, ["afade=t=in:d=0.003", tail_fade(cut, 0.04)], channels, norm, target))
                cut.unlink()
            decoded.unlink()
            continue
        n += 1
        dst = out_dir / f"{c['id']}_{n:02d}.wav"
        loop = c.get("loop")
        if loop == "native":
            # ElevenLabs made it loop: keep every sample; only drop decoder padding at the edges.
            filters = ["silenceremove=start_periods=1:start_threshold=-90dB",
                       "areverse", "silenceremove=start_periods=1:start_threshold=-90dB", "areverse"]
            results.append(finish(ctx, c, raw, dst, filters, channels, norm, target))
        elif loop == "xfade":
            # Seamless loop: the last X seconds crossfade (equal power) into the start; the loop is L - X long.
            x = float(c.get("xfade", 2.0))
            decoded = out_dir / (raw.stem + ".decoded.wav")
            ff("-i", raw, "-ac", channels, "-ar", SR, "-c:a", "pcm_f32le", decoded)
            length = duration_of(decoded)
            x = min(x, length / 4)
            graph = (f"[0:a]asplit=2[a][b];[a]atrim=start={length - x:.4f},asetpts=PTS-STARTPTS[tail];"
                     f"[b]atrim=end={length - x:.4f},asetpts=PTS-STARTPTS[body];"
                     f"[tail][body]acrossfade=d={x:.4f}:c1=qsin:c2=qsin[out]")
            looped = out_dir / (raw.stem + ".loop.wav")
            ff("-i", decoded, "-filter_complex", graph, "-map", "[out]", "-c:a", "pcm_f32le", looped)
            results.append(finish(ctx, c, looped, dst, [], channels, norm, target))
            decoded.unlink()
            looped.unlink()
        else:
            cap = c.get("max_len")
            trimmed = out_dir / (raw.stem + ".trim.wav")
            ff("-i", raw, "-af", ",".join(one_shot_filters(c, cap)), "-ac", channels, "-ar", SR, "-c:a", "pcm_f32le", trimmed)
            fade = float(c.get("fade_out", 0.08))
            results.append(finish(ctx, c, trimmed, dst, [tail_fade(trimmed, fade)], channels, norm, target))
            trimmed.unlink()
    return results


def cmd_process(ctx: Ctx):
    need_ffmpeg()
    report = {}
    for c in ctx.selected():
        r = process_cue(ctx, c)
        if r is None:
            continue
        report[c["id"]] = r
        log(f"  {c['id']}: {len(r)} takes, " + ", ".join(f"{t['seconds']:.2f}s" for t in r[:6]) + (" ..." if len(r) > 6 else ""))
    (ctx.work).mkdir(parents=True, exist_ok=True)
    path = ctx.work / "takes.json"
    old = json.loads(path.read_text()) if path.exists() else {}
    old.update(report)
    path.write_text(json.dumps(old, indent=1))
    log(f"process: {len(report)} cues -> {ctx.work / 'takes'}")


# --------------------------------------------------------------------------------------------
# bank


def read_wav(path: Path):
    with wave.open(str(path), "rb") as w:
        return w.getnchannels(), w.getframerate(), w.readframes(w.getnframes())


def encode_upload(src: Path, dst_stem: Path, channels: int) -> Path:
    """FLAC (lossless, gapless) unless it's over the upload limit: then OGG (stereo) or MP3 (mono)."""
    flac = dst_stem.with_suffix(".flac")
    ff("-i", src, "-c:a", "flac", "-compression_level", "8", flac)
    if flac.stat().st_size <= UPLOAD_LIMIT:
        return flac
    flac.unlink()
    if channels == 2:
        out = dst_stem.with_suffix(".ogg")
        ff("-i", src, "-c:a", "vorbis", "-strict", "-2", "-q:a", "8", out)
    else:
        out = dst_stem.with_suffix(".mp3")
        ff("-i", src, "-c:a", "libmp3lame", "-q:a", "0", out)
    return out


def cmd_bank(ctx: Ctx):
    need_ffmpeg()
    takes_root = ctx.work / "takes"
    upload = ctx.out / "upload"
    preview = ctx.out / "preview"
    for d in (upload, preview):
        if d.exists():
            shutil.rmtree(d)
        d.mkdir(parents=True)
    gap = float(ctx.defaults.get("gap", 0.3))
    manifest = {"made": datetime.datetime.now().isoformat(timespec="seconds"), "files": {}}

    def takes_of(c):
        return sorted(p for p in (takes_root / c["id"]).glob(f"{c['id']}_*.wav")) if (takes_root / c["id"]).exists() else []

    # Banks: every take of every cue in one file, a gap of silence around each; regions per take.
    for name, bank in ctx.banks.items():
        members = [c for c in ctx.cues if c.get("bank") == name and takes_of(c)]
        if not members:
            continue
        channels = int(bank["channels"])
        pad = b"\x00\x00" * channels * int(gap * SR)
        frames, cues = [pad], {}
        cursor = len(pad) // (2 * channels)
        for c in members:
            for path in takes_of(c):
                ch, sr, data = read_wav(path)
                if ch != channels or sr != SR:
                    sys.exit(f"{path}: {ch} ch {sr} Hz, bank {name} wants {channels} ch {SR} Hz (re-run process)")
                n = len(data) // (2 * channels)
                cues.setdefault(c["id"], []).append([round(cursor / SR, 4), round((cursor + n) / SR, 4)])
                frames += [data, pad]
                cursor += n + len(pad) // (2 * channels)
        wav = ctx.work / f"bank_{name}.wav"
        with wave.open(str(wav), "wb") as w:
            w.setnchannels(channels)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(b"".join(frames))
        out = encode_upload(wav, upload / f"bank_{name}", channels)
        ff("-i", wav, "-c:a", "libmp3lame", "-q:a", "2", preview / f"bank_{name}.mp3")
        manifest["files"][out.name] = {"sha256": sha256(out), "seconds": round(cursor / SR, 2), "cues": cues}
        log(f"  {out.name}: {sum(len(v) for v in cues.values())} takes, {cursor / SR:.1f} s, {out.stat().st_size / 1e6:.1f} MB")

    # Loops (music, ambience): one asset per cue (its first take), played whole and looped.
    for c in ctx.cues:
        if c.get("bank"):
            continue
        takes = takes_of(c)
        if not takes:
            continue
        channels, _, _ = settings_of(ctx, c)
        out = encode_upload(takes[0], upload / c["id"], channels)
        ff("-i", takes[0], "-c:a", "libmp3lame", "-q:a", "2", preview / f"{c['id']}.mp3")
        if channels == 2:
            ff("-i", takes[0], "-c:a", "vorbis", "-strict", "-2", "-q:a", "6", preview / f"{c['id']}.ogg")
        manifest["files"][out.name] = {"sha256": sha256(out), "seconds": round(duration_of(out), 2), "cues": {c["id"]: [None]}}
        log(f"  {out.name}: {duration_of(out):.1f} s, {out.stat().st_size / 1e6:.1f} MB")

    (ctx.out / "manifest.json").write_text(json.dumps(manifest, indent=1))
    log(f"bank: {len(manifest['files'])} files -> {upload} (previews in {preview})")


# --------------------------------------------------------------------------------------------
# upload / link / ids


def load_ids(ctx: Ctx) -> dict:
    return json.loads(ctx.ids_json.read_text()) if ctx.ids_json.exists() else {"files": {}}


def save_ids(ctx: Ctx, ids: dict):
    ctx.ids_json.parent.mkdir(parents=True, exist_ok=True)
    ctx.ids_json.write_text(json.dumps(ids, indent=1, sort_keys=True) + "\n")


def creator_of(args):
    if getattr(args, "user_id", None):
        return {"userId": str(args.user_id)}
    if getattr(args, "group_id", None):
        return {"groupId": str(args.group_id)}
    if ROBLOX_CREATOR.exists():
        kind, _, num = ROBLOX_CREATOR.read_text().strip().partition(":")
        if kind in ("user", "group") and num.isdigit():
            return {("userId" if kind == "user" else "groupId"): num}
    return None


CONTENT_TYPES = {".flac": "audio/flac", ".ogg": "audio/ogg", ".mp3": "audio/mpeg", ".wav": "audio/wav"}


def multipart(fields: dict, file_field: str, path: Path):
    boundary = uuid.uuid4().hex
    parts = []
    for k, v in fields.items():
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
    parts.append((f"--{boundary}\r\nContent-Disposition: form-data; name=\"{file_field}\"; filename=\"{path.name}\"\r\n"
                  f"Content-Type: {CONTENT_TYPES[path.suffix]}\r\n\r\n").encode())
    parts.append(path.read_bytes())
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def roblox_upload(key: str, creator: dict, path: Path, display: str) -> str:
    request = {"assetType": "Audio", "displayName": display[:50], "description": "LAST BLADE sound (art/sound)",
               "creationContext": {"creator": creator}}
    body, ctype = multipart({"request": json.dumps(request)}, "fileContent", path)
    try:
        _, _, payload = http("POST", f"{ROBLOX_ASSETS}/assets", {"x-api-key": key, "Content-Type": ctype}, body)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Open Cloud {e.code}: {e.read()[:500].decode('utf-8', 'replace')}") from None
    op = json.loads(payload)
    for _ in range(90):
        if op.get("done"):
            resp = op.get("response") or {}
            if resp.get("assetId"):
                state = (resp.get("moderationResult") or {}).get("moderationState", "")
                if state and state != "MODERATION_STATE_APPROVED":
                    log(f"    moderation: {state}")
                return str(resp["assetId"])
            raise RuntimeError(f"upload finished without an asset id: {json.dumps(op)[:400]}")
        time.sleep(2)
        op_id = (op.get("path") or "").split("/")[-1] or op.get("operationId")
        _, _, payload = http("GET", f"{ROBLOX_ASSETS}/operations/{op_id}", {"x-api-key": key})
        op = json.loads(payload)
    raise RuntimeError("upload still processing after 3 minutes; run upload again later")


def cmd_upload(ctx: Ctx):
    manifest_path = ctx.out / "manifest.json"
    if not manifest_path.exists():
        sys.exit("no out/manifest.json: run bank first")
    manifest = json.loads(manifest_path.read_text())
    ids = load_ids(ctx)
    pending = [(name, f) for name, f in manifest["files"].items()
               if ids["files"].get(name, {}).get("sha256") != f["sha256"]]
    if not pending:
        log("upload: everything is uploaded")
        write_audio_ids(ctx, ids)
        return
    if getattr(ctx.args, "bulk", False) or (not ROBLOX_KEY.exists() and not ctx.dry):
        import_folder(ctx, manifest, pending)
        return
    creator = creator_of(ctx.args) or ({"userId": "0"} if ctx.dry else None)
    if not creator:
        sys.exit(f"no creator: pass --user-id N or --group-id N, or write 'user:N' / 'group:N' to {ROBLOX_CREATOR}")
    key = "dry-run" if ctx.dry else read_key(ROBLOX_KEY, "Roblox Open Cloud")
    log(f"upload: {len(pending)} files{' (dry run: fake ids)' if ctx.dry else ''}")
    for i, (name, f) in enumerate(pending):
        path = ctx.out / "upload" / name
        if ctx.dry:
            asset = str(9_000_000_000 + int(hashlib.sha256((name + f["sha256"]).encode()).hexdigest()[:6], 16))
        else:
            asset = roblox_upload(key, creator, path, f"LB {Path(name).stem}")
        ids["files"][name] = {"assetId": asset, "sha256": f["sha256"], "cues": f["cues"],
                              "uploaded": datetime.datetime.now().isoformat(timespec="seconds")}
        save_ids(ctx, ids)  # after each file: a failure later keeps what's done
        log(f"  {name} -> {asset}")
    write_audio_ids(ctx, ids)


def import_folder(ctx: Ctx, manifest: dict, pending):
    folder = ctx.out / "upload"
    names = [n for n, _ in pending]
    lines = [
        "LAST BLADE audio, ready for a bulk import (no Open Cloud key found).",
        "",
        "1. Studio: Window > Asset Manager > Bulk Import, pick every file in this folder",
        "   (or Creator Hub > Creations > Audio > Upload). Name them as the files are named.",
        "2. Copy each new asset id, then from art/sound run:",
        "     python3 sound.py link " + " ".join(f"{n}=<id>" for n in names[:2]) + " ...",
        "   or put 'file,assetId' lines in a CSV and run: python3 sound.py link --csv ids.csv",
        "3. That writes art/sound/ids.json and src/shared/AudioIds.luau; commit both.",
        "",
        "Files:",
        *[f"  {n}" for n in names],
    ]
    (folder / "IMPORT.txt").write_text("\n".join(lines) + "\n")
    template = folder / "ids_template.csv"
    with open(template, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["file", "assetId"])
        for n in names:
            w.writerow([n, ""])
    log(f"upload: no Open Cloud key at {ROBLOX_KEY}; {len(names)} files ready for a bulk import in {folder}")
    log(f"  instructions: {folder / 'IMPORT.txt'}; fill {template} and run: python3 sound.py link --csv {template}")


def cmd_link(ctx: Ctx):
    manifest = json.loads((ctx.out / "manifest.json").read_text())
    pairs = []
    if ctx.args.csv:
        with open(ctx.args.csv, newline="") as f:
            for row in csv.DictReader(f):
                if row.get("assetId", "").strip():
                    pairs.append((row["file"].strip(), row["assetId"].strip()))
    for item in ctx.args.pairs or []:
        name, _, asset = item.partition("=")
        pairs.append((name.strip(), asset.strip()))
    ids = load_ids(ctx)
    for name, asset in pairs:
        asset = re.sub(r"\D", "", asset)
        if name not in manifest["files"]:
            sys.exit(f"{name}: not in out/manifest.json (files: {', '.join(manifest['files'])})")
        if not asset:
            sys.exit(f"{name}: no asset id")
        f = manifest["files"][name]
        ids["files"][name] = {"assetId": asset, "sha256": f["sha256"], "cues": f["cues"],
                              "uploaded": datetime.datetime.now().isoformat(timespec="seconds")}
        log(f"  {name} -> {asset}")
    save_ids(ctx, ids)
    write_audio_ids(ctx, ids)


def write_audio_ids(ctx: Ctx, ids: dict):
    """src/shared/AudioIds.luau from ids.json: cue -> takes (asset id, region in a bank)."""
    entries = {}
    for name, f in ids["files"].items():
        asset = f"rbxassetid://{f['assetId']}"
        for cue, regions in f["cues"].items():
            for r in regions:
                take = {"id": asset}
                if r:
                    take["from"], take["to"] = r[0], r[1]
                entries.setdefault(cue, []).append(take)
    out = [
        "--!strict",
        "-- GENERATED by art/sound/sound.py (upload / link). Do not edit by hand: rerun the script.",
        "-- Generated takes per cue id (research_notes/sound/sound_plan.md, art/sound/cues.json). A take",
        "-- is an asset, or a region of a bank asset (`from`/`to` in seconds, played with",
        "-- Sound.PlaybackRegion). client/Audio plays these in place of the library placeholders.",
        "",
        "export type Take = { id: string, from: number?, to: number? }",
        "",
    ]
    if not entries:
        out.append("local AudioIds: { [string]: { Take } } = {}")
    else:
        out.append("local AudioIds: { [string]: { Take } } = {")
        for cue in sorted(entries):
            out.append(f"\t{cue} = {{")
            for t in entries[cue]:
                if "from" in t:
                    out.append(f"\t\t{{ id = \"{t['id']}\", from = {t['from']:.4f}, to = {t['to']:.4f} }},")
                else:
                    out.append(f"\t\t{{ id = \"{t['id']}\" }},")
            out.append("\t},")
        out.append("}")
    out += ["", "return AudioIds", ""]
    ctx.audio_ids.parent.mkdir(parents=True, exist_ok=True)
    ctx.audio_ids.write_text("\n".join(out))
    n = sum(len(v) for v in entries.values())
    log(f"ids: {len(entries)} cues, {n} takes -> {ctx.audio_ids}")
    if shutil.which("stylua"):
        p = subprocess.run(["stylua", "--check", str(ctx.audio_ids)], cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if p.returncode != 0:
            subprocess.run(["stylua", str(ctx.audio_ids)], cwd=REPO)


def cmd_ids(ctx: Ctx):
    write_audio_ids(ctx, load_ids(ctx))


def cmd_all(ctx: Ctx):
    if not cmd_check(ctx):
        sys.exit("fix check problems first")
    cmd_generate(ctx)
    cmd_process(ctx)
    cmd_bank(ctx)
    cmd_upload(ctx)


# --------------------------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--dry-run", action="store_true", help="no network; synthetic audio and fake ids in art/sound/.dryrun/")
        p.add_argument("--only", default="", help="comma-separated cue ids or bank names")
        p.add_argument("--priority", default="", help="comma-separated priorities, e.g. P0,P1")
        return p

    common(sub.add_parser("plan")).add_argument("--markdown", action="store_true")
    common(sub.add_parser("check"))
    for name in ("generate", "all"):
        p = common(sub.add_parser(name))
        p.add_argument("--force", action="store_true", help="remake takes that already exist (costs credits)")
        p.add_argument("--regen-changed", action="store_true", help="remake takes whose prompt changed")
        p.add_argument("--jobs", type=int, default=3)
        p.add_argument("--music-model", default=None, help="music_v2_5 (default), music_v2 or music_v1")
        if name == "all":
            p.add_argument("--user-id")
            p.add_argument("--group-id")
            p.add_argument("--bulk", action="store_true", help="make the bulk-import folder even with an Open Cloud key")
    common(sub.add_parser("process"))
    common(sub.add_parser("bank"))
    p = common(sub.add_parser("upload"))
    p.add_argument("--user-id")
    p.add_argument("--group-id")
    p.add_argument("--bulk", action="store_true", help="make the bulk-import folder even with an Open Cloud key")
    p = common(sub.add_parser("link"))
    p.add_argument("pairs", nargs="*", help="FILE=ASSETID")
    p.add_argument("--csv")
    common(sub.add_parser("ids"))
    args = ap.parse_args()
    ctx = Ctx(args)
    {
        "plan": cmd_plan, "check": lambda c: sys.exit(0 if cmd_check(c) else 1), "generate": cmd_generate,
        "process": cmd_process, "bank": cmd_bank, "upload": cmd_upload, "link": cmd_link, "ids": cmd_ids,
        "all": cmd_all,
    }[args.cmd](ctx)


if __name__ == "__main__":
    main()
