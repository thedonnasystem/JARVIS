"""FENDEZY AI CREATIVE STUDIO M8c: local media tools for the editing step. Free (runs on the Jarvis host), no network, no provider.

- captions: faster-whisper (MIT, SYSTRAN/faster-whisper) transcribes on the CPU with word timestamps; without it (or without speech) the words of the
  script are timed evenly. Words become an SRT file (soft track + sidecar) and an ASS file burned in with the office's caption style (word highlight,
  pop-in, lyric lines) plus the optional hook banner and the ALWAYS-ON "AI-generated" label.
- editing (ffmpeg only; MoviePy is not needed): loudness normalisation (EBU R128 two-pass loudnorm), auto-reframe (crop window on the visual-energy centre of
  each clip), hook-first ordering (most motion first), B-roll stitching (hard cuts or crossfades), beat-synced cuts (librosa ISC when installed, otherwise
  an onset-energy beat tracker in pure Python), audio visualizer / lyric video for music.
Nothing here can switch the disclosure off: finish() always draws the label and writes the metadata comment.
"""
from __future__ import annotations

import array
import json
import math
import os
import re
import shutil
import subprocess
import tempfile

DISCLOSURE = "AI-generated content."
LABEL = "AI-generated"
PLATFORMS = {"9:16": (1080, 1920), "1:1": (1080, 1080), "16:9": (1920, 1080)}


class MediaError(Exception):
    pass


def _run(cmd: list[str], timeout: int = 600, binary: bool = False):
    r = subprocess.run(cmd, capture_output=True, timeout=timeout)
    if r.returncode != 0:
        raise MediaError(f"{os.path.basename(cmd[0])} failed: " + r.stderr.decode(errors="replace")[-300:])
    return r.stdout if binary else r.stdout.decode(errors="replace")


def ff(args: list[str], timeout: int = 600) -> None:
    _run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], timeout=timeout)


def probe(path: str) -> dict:
    out = _run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type,width,height,r_frame_rate:format=duration", "-of", "json", path], timeout=60)
    j = json.loads(out or "{}")
    v = next((s for s in j.get("streams", []) if s.get("codec_type") == "video"), {})
    return {"width": v.get("width"), "height": v.get("height"), "duration": float((j.get("format") or {}).get("duration") or 0),
            "audio": any(s.get("codec_type") == "audio" for s in j.get("streams", [])), "video": bool(v)}


# ------------------------------------------------------------------------------------------------------------------- captions
WHISPER_TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "creative_studio", "tools", "whisper_words.py")


def speech_words(path: str, model: str | None = None, env: dict | None = None) -> list[dict]:
    """Word timings [{word, start, end}] from faster-whisper on the CPU (int8), run in a separate process (creative_studio/tools/whisper_words.py) so
    the model's memory is freed after each file. The model is read from CREATIVE_WHISPER_DIR (no download) unless CREATIVE_WHISPER_DOWNLOAD=1.
    Raises MediaError when faster-whisper or the model is missing, so the caller falls back to script timing."""
    import sys
    env = os.environ if env is None else env
    name = model or env.get("CREATIVE_WHISPER_MODEL") or "tiny"
    if not re.fullmatch(r"[a-z0-9.-]{2,30}", name):
        raise MediaError("bad whisper model name")
    cmd = [sys.executable, "-I", WHISPER_TOOL, "--model", name] + (["--dir", env["CREATIVE_WHISPER_DIR"]] if env.get("CREATIVE_WHISPER_DIR") else []) + \
          (["--allow-download"] if env.get("CREATIVE_WHISPER_DOWNLOAD") == "1" else []) + ["--", path]
    r = subprocess.run(cmd, capture_output=True, timeout=1200)
    try:
        out = json.loads(r.stdout.decode(errors="replace").strip().splitlines()[-1])
    except (ValueError, IndexError):
        raise MediaError(f"whisper failed ({r.returncode})") from None
    if isinstance(out, dict):
        raise MediaError(str(out.get("error") or "whisper failed"))
    return [w for w in out if isinstance(w, dict) and {"word", "start", "end"} <= set(w)]


def _norm(t: str) -> str:
    return re.sub(r"[^a-z0-9']", "", (t or "").lower())


def align_to_script(words: list[dict], script: str, min_ratio: float = 0.5) -> tuple[list[dict], bool]:
    """When the speech IS the known script (our own voice-over or lyrics), keep whisper's timings but the script's spelling: matched words take the
    script word, unmatched spans share their time among the script words they replace. Below min_ratio similarity the transcript is kept as is."""
    import difflib
    toks = [t for t in re.split(r"\s+", (script or "").strip()) if t]
    if not words or not toks:
        return words, False
    a, b = [_norm(w["word"]) for w in words], [_norm(t) for t in toks]
    sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    if sm.ratio() < min_ratio:
        return words, False
    out = []
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == "equal":
            out += [{"word": toks[j1 + k], "start": words[i1 + k]["start"], "end": words[i1 + k]["end"]} for k in range(i2 - i1)]
        elif j2 > j1:
            if i2 > i1:
                s, e = words[i1]["start"], words[i2 - 1]["end"]
            else:                                                        # script words whisper missed: squeeze them into the gap before the next word
                s = out[-1]["end"] if out else 0.0
                e = words[i1]["start"] if i1 < len(words) else s + 0.3 * (j2 - j1)
                e = max(e, s + 0.05 * (j2 - j1))
            step = (e - s) / (j2 - j1)
            out += [{"word": toks[j1 + k], "start": round(s + k * step, 3), "end": round(s + (k + 1) * step, 3)} for k in range(j2 - j1)]
    return out, True


def script_words(text: str, seconds: float) -> list[dict]:
    """Even timing from the script (weighted by word length) when there is no transcript."""
    toks = [t for t in re.split(r"\s+", (text or "").strip()) if t][:400]
    if not toks or seconds <= 0:
        return []
    weights = [len(t) + 2 for t in toks]
    total, t0, out = sum(weights), 0.0, []
    for tok, wgt in zip(toks, weights):
        d = seconds * wgt / total
        out.append({"word": tok, "start": round(t0, 3), "end": round(t0 + d, 3)})
        t0 += d
    return out


def lines(words: list[dict], per_line: int) -> list[list[dict]]:
    """Group words into caption lines: at most per_line words, and a new line after sentence punctuation or a pause over 0.6 s."""
    out, cur = [], []
    for i, w in enumerate(words):
        if cur and (len(cur) >= per_line or re.search(r"[.!?]$", cur[-1]["word"]) or w["start"] - cur[-1]["end"] > 0.6):
            out.append(cur)
            cur = []
        cur.append(w)
    if cur:
        out.append(cur)
    return out


def _ts_srt(s: float) -> str:
    s = max(0.0, s)
    ms = int(round(s * 1000))
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"


def _ts_ass(s: float) -> str:
    cs = int(round(max(0.0, s) * 100))
    return f"{cs // 360000}:{cs // 6000 % 60:02d}:{cs // 100 % 60:02d}.{cs % 100:02d}"


def to_srt(words: list[dict], per_line: int = 7) -> str:
    return "".join(f"{i + 1}\n{_ts_srt(ln[0]['start'])} --> {_ts_srt(ln[-1]['end'])}\n{' '.join(w['word'] for w in ln)}\n\n"
                   for i, ln in enumerate(lines(words, per_line)))


def _ass_colour(hex6: str, alpha: int = 0) -> str:
    h = hex6.lstrip("#")
    return f"&H{alpha:02X}{h[4:6]}{h[2:4]}{h[0:2]}".upper()


def _ass_text(s: str) -> str:
    return re.sub(r"[{}\\]", "", s or "").replace("\n", " ")


def to_ass(words: list[dict], style: dict | None, size: tuple[int, int], duration: float, hook: str | None = None, label: str = LABEL) -> str:
    """ASS subtitles: the caption style (word-highlight / pop-in / none), the hook banner for the first 2.5 s, and the AI label for the whole video."""
    w, h = size
    scale = h / 1920 if h >= w else w / 1920
    st = style or {}
    fs = max(18, int(int(st.get("size", 64)) * scale)) if st else 40
    align = {"lower": 2, "center": 5, "upper": 8}.get(st.get("position", "lower"), 2)
    margin_v = int(h * (0.14 if align == 2 else 0.05))
    bold = -1 if st.get("bold") else 0
    prim, hi, outl = (_ass_colour(st.get(k, d)) for k, d in (("primary", "#FFFFFF"), ("highlight", "#F4C430"), ("outline", "#000000")))
    font = re.sub(r"[,\n]", "", st.get("font", "DejaVu Sans"))
    lab = max(16, int(30 * scale))
    out = ["[Script Info]", "ScriptType: v4.00+", f"PlayResX: {w}", f"PlayResY: {h}", "WrapStyle: 0", "ScaledBorderAndShadow: yes", "",
           "[V4+ Styles]",
           "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, "
           "Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
           f"Style: Cap,{font},{fs},{prim},{hi},{outl},&H80000000,{bold},0,0,0,100,100,0,0,1,{int(st.get('outline_px', 4) * scale + 1)},{int(st.get('shadow_px', 1) * scale)},{align},60,60,{margin_v},1",
           f"Style: Hook,{font},{int(fs * 1.1)},{prim},{hi},{outl},&H80000000,-1,0,0,0,100,100,0,0,3,{int(6 * scale + 1)},0,8,60,60,{int(h * 0.08)},1",
           f"Style: Label,DejaVu Sans,{lab},&H33FFFFFF,&H33FFFFFF,&H80000000,&H80000000,0,0,0,0,100,100,0,0,1,{max(1, int(2 * scale))},0,9,30,30,30,1",
           "", "[Events]", "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"]
    end_all = max(duration, words[-1]["end"] if words else 0.0, 0.5)
    out.append(f"Dialogue: 2,{_ts_ass(0)},{_ts_ass(end_all)},Label,,0,0,0,,{_ass_text(label)}")
    if hook:
        out.append(f"Dialogue: 1,{_ts_ass(0)},{_ts_ass(min(2.5, end_all))},Hook,,0,0,0,,{{\\fad(120,200)}}{_ass_text(hook)}")
    anim = st.get("animation", "none") if st else None
    if st and words:
        upper = bool(st.get("uppercase"))
        hi_tag = "{\\c" + hi + "}"
        prim_tag = "{\\c" + prim + "}"
        for ln in lines(words, int(st.get("words_per_line", 3))):
            toks = [(_ass_text(x["word"]).upper() if upper else _ass_text(x["word"])) for x in ln]
            if anim == "pop-in":
                for x, t in zip(ln, toks):
                    out.append(f"Dialogue: 0,{_ts_ass(x['start'])},{_ts_ass(x['end'])},Cap,,0,0,0,,{{\\fscx70\\fscy70\\t(0,90,\\fscx100\\fscy100)}}{t}")
            elif anim == "word-highlight":
                for i, x in enumerate(ln):
                    nxt = ln[i + 1]["start"] if i + 1 < len(ln) else x["end"]
                    txt = " ".join((hi_tag + t + prim_tag) if j == i else t for j, t in enumerate(toks))
                    out.append(f"Dialogue: 0,{_ts_ass(x['start'])},{_ts_ass(max(nxt, x['start'] + 0.05))},Cap,,0,0,0,,{txt}")
            else:
                out.append(f"Dialogue: 0,{_ts_ass(ln[0]['start'])},{_ts_ass(ln[-1]['end'])},Cap,,0,0,0,,{' '.join(toks)}")
    return "\n".join(out) + "\n"


def _filter_path(p: str) -> str:
    """A path safe inside an ffmpeg filter argument (we only write our own temp paths, but escape anyway)."""
    return p.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'").replace(",", "\\,")


# ------------------------------------------------------------------------------------------------------------------- audio
def loudness(path: str, target: float = -14.0) -> dict | None:
    """First loudnorm pass: measured values (None when the file has no audio)."""
    if not probe(path)["audio"]:
        return None
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-vn", "-af", f"loudnorm=I={target}:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"],
                       capture_output=True, timeout=600)
    m = re.search(r"\{[^{}]*\"input_i\"[^{}]*\}", r.stderr.decode(errors="replace"))
    if r.returncode != 0 or not m:
        raise MediaError("loudness measurement failed")
    j = json.loads(m.group(0))
    if j.get("input_i") in ("-inf", None):
        return None
    return {k: float(j[k]) for k in ("input_i", "input_tp", "input_lra", "input_thresh", "target_offset")}


def loudnorm_filter(measured: dict | None, target: float = -14.0) -> str | None:
    if not measured:
        return None
    return (f"loudnorm=I={target}:TP=-1.5:LRA=11:measured_I={measured['input_i']}:measured_TP={measured['input_tp']}:measured_LRA={measured['input_lra']}"
            f":measured_thresh={measured['input_thresh']}:offset={measured['target_offset']}:linear=true")


def _pcm(path: str, rate: int = 8000, seconds: float | None = None) -> array.array:
    args = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path] + (["-t", str(seconds)] if seconds else []) + ["-vn", "-ac", "1", "-ar", str(rate), "-f", "s16le", "-"]
    a = array.array("h")
    a.frombytes(_run(args, binary=True, timeout=600)[: 2 * rate * 600])
    return a


def onset_envelope(pcm, rate: int = 8000, hop: int = 128) -> tuple[list[float], float]:
    """Half-wave rectified log-energy difference per hop (an energy onset detector). Returns (envelope, frames per second)."""
    env, prev = [], None
    for i in range(0, max(0, len(pcm) - hop), hop):
        e = 0
        for s in pcm[i:i + hop]:
            e += s * s
        le = math.log1p(e / hop)
        env.append(max(0.0, le - prev) if prev is not None else 0.0)
        prev = le
    return env, rate / hop


def beats(path: str, bpm_range: tuple[int, int] = (70, 180)) -> dict:
    """Beat times of the audio. librosa (ISC) when importable; otherwise tempo by autocorrelation of the onset envelope and the beat phase that best
    lines up with onsets."""
    try:
        import librosa  # ISC; optional
        import numpy as np
        sr = 22050
        y = np.frombuffer(_run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path, "-t", "600", "-vn", "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"],
                               binary=True, timeout=600), dtype=np.float32)
        tempo, frames = librosa.beat.beat_track(y=y, sr=sr, units="frames")
        times = [round(float(t), 3) for t in librosa.frames_to_time(frames, sr=sr)]
        t = float(tempo[0] if hasattr(tempo, "__len__") else tempo)
        if len(times) >= 2:
            return {"bpm": round(t, 1), "beats": times, "method": "librosa"}
    except Exception:
        pass
    pcm = _pcm(path)
    env, fps = onset_envelope(pcm)
    n = len(env)
    if n < fps * 2:
        return {"bpm": None, "beats": [], "method": "none"}
    mean = sum(env) / n
    x = [v - mean for v in env]
    lo, hi = int(fps * 60 / bpm_range[1]), int(fps * 60 / bpm_range[0]) + 1
    best_lag, best = lo, -1e18
    for lag in range(max(1, lo), min(hi, n // 2)):
        c = sum(x[i] * x[i + lag] for i in range(0, n - lag)) / (n - lag)
        c *= 1.0 - 0.15 * abs(math.log2((fps * 60 / lag) / 120.0))     # mild prior towards ~120 BPM (dance / pop / hip-hop)
        if c > best:
            best, best_lag = c, lag
    phase = max(range(best_lag), key=lambda p: sum(env[i] for i in range(p, n, best_lag)))
    times = [round(i / fps, 3) for i in range(phase, n, best_lag)]
    return {"bpm": round(fps * 60 / best_lag, 1), "beats": times, "method": "onset-autocorrelation"}


# ------------------------------------------------------------------------------------------------------------------- video analysis
def _gray_frames(path: str, fps: float = 2.0, w: int = 64, h: int = 36, seconds: float | None = None) -> list[bytes]:
    args = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path] + (["-t", str(seconds)] if seconds else []) + \
           ["-vf", f"fps={fps},scale={w}:{h}:flags=area,format=gray", "-f", "rawvideo", "-"]
    raw = _run(args, binary=True, timeout=600)
    return [raw[i:i + w * h] for i in range(0, len(raw) - w * h + 1, w * h)]


def subject_center(path: str, w: int = 64, h: int = 36) -> float:
    """Horizontal centre (0..1) of visual energy (gradient magnitude) across sampled frames; 0.5 when the picture is flat."""
    frames = _gray_frames(path, w=w, h=h)
    cols = [0.0] * w
    for fr in frames:
        for y in range(1, h - 1):
            row = y * w
            for x in range(1, w - 1):
                gx = fr[row + x + 1] - fr[row + x - 1]
                gy = fr[row + w + x] - fr[row - w + x]
                cols[x] += abs(gx) + abs(gy)
    total = sum(cols)
    if total <= 0:
        return 0.5
    return min(1.0, max(0.0, sum(i * c for i, c in enumerate(cols)) / total / (w - 1)))


def motion_score(path: str) -> float:
    """Mean absolute frame difference (0..255) of a low-res copy: the hook-first order puts the liveliest clip first."""
    frames = _gray_frames(path, fps=4.0, w=32, h=18)
    if len(frames) < 2:
        return 0.0
    tot = 0
    for a, b in zip(frames, frames[1:]):
        tot += sum(abs(x - y) for x, y in zip(a, b))
    return round(tot / ((len(frames) - 1) * len(frames[0])), 3)


def fit_filter(src_w: int, src_h: int, platform: str, fit: str = "pad", center: float = 0.5, pad_colour: str = "black") -> str:
    """Video filter to the platform frame. pad: scale inside + pad (brand colour). auto_reframe: crop the largest window of the target aspect around the
    subject centre, then scale (no bars)."""
    w, h = PLATFORMS[platform]
    if fit == "auto_reframe" and src_w and src_h:
        ta = w / h
        if src_w / src_h > ta:                                   # too wide: crop width
            cw = int(src_h * ta) // 2 * 2
            x = int(min(max(center * src_w - cw / 2, 0), src_w - cw))
            return f"crop={cw}:{src_h // 2 * 2}:{x}:0,scale={w}:{h},setsar=1"
        ch = int(src_w / ta) // 2 * 2
        y = int(max(0, (src_h - ch) / 2))
        return f"crop={src_w // 2 * 2}:{ch}:0:{y},scale={w}:{h},setsar=1"
    colour = pad_colour if re.fullmatch(r"#[0-9A-Fa-f]{6}|black|white", pad_colour or "") else "black"
    colour = colour.replace("#", "0x")
    return f"scale={w}:{h}:force_original_aspect_ratio=decrease,pad={w}:{h}:(ow-iw)/2:(oh-ih)/2:color={colour},setsar=1"


# ------------------------------------------------------------------------------------------------------------------- finish: the render step
def finish(src: str, platform: str, out: str, *, script: str = "", style: dict | None = None, hook: str | None = None, fit: str = "pad",
           pad_colour: str = "black", loudnorm: float | None = -14.0, transcriber=None, workdir: str | None = None, script_fallback: bool = True) -> dict:
    """Platform-ready file. Video: fit -> burned captions (style) + hook + AI label -> loudness-normalised AAC -> H.264, soft SRT track, disclosure in the
    metadata. Image: fit + AI label. Returns {'srt', 'words', 'caption_source', 'loudness', 'center'}."""
    info = probe(src)
    w, h = PLATFORMS[platform]
    tmp = workdir or tempfile.mkdtemp(prefix="cs-finish-")
    center = 0.5
    if fit == "auto_reframe" and info["video"]:
        try:
            center = subject_center(src)
        except MediaError:
            center = 0.5
    vf = fit_filter(info["width"] or w, info["height"] or h, platform, fit, center, pad_colour)
    if out.endswith((".png", ".jpg", ".webp")):
        ass = os.path.join(tmp, "label.ass")
        with open(ass, "w") as f:
            f.write(to_ass([], None, (w, h), 1.0))
        ff(["-i", src, "-vf", f"{vf},ass='{_filter_path(ass)}'", "-frames:v", "1", out])
        return {"srt": "", "words": [], "caption_source": None, "loudness": None, "center": round(center, 3)}
    dur = info["duration"] or 3.0
    words, source = [], None
    if style and info["audio"]:
        try:
            words = (transcriber or speech_words)(src)
            source = "whisper" if words else None
        except MediaError:
            words = []
        if words and script:
            words, aligned = align_to_script(words, script)
            source = "whisper+script" if aligned else source
    if style and not words and script and script_fallback:
        words, source = script_words(script, dur), "script"
    words = [x for x in words if x["start"] < dur]
    srt_text = to_srt(words, int((style or {}).get("words_per_line", 7))) if words else ""
    ass = os.path.join(tmp, os.path.basename(out) + ".ass")
    with open(ass, "w") as f:
        f.write(to_ass(words, style, (w, h), dur, hook=hook))
    args = ["-i", src]
    maps = ["-map", "0:v"]
    if srt_text:
        srt_file = os.path.join(tmp, os.path.basename(out) + ".srt")
        with open(srt_file, "w") as f:
            f.write(srt_text)
        args += ["-i", srt_file]
        maps += ["-map", "1:s", "-c:s", "mov_text", "-metadata:s:s:0", "language=eng"]
    measured = None
    if info["audio"]:
        maps += ["-map", "0:a"]
        if loudnorm is not None:
            measured = loudness(src, loudnorm)
            af = loudnorm_filter(measured, loudnorm)
            if af:
                maps += ["-af", af, "-ar", "48000"]
    ff(args + maps + ["-vf", f"{vf},ass='{_filter_path(ass)}'", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k",
                      "-movflags", "+faststart", "-metadata", "comment=" + DISCLOSURE, out], timeout=1200)
    return {"srt": srt_text, "words": words, "caption_source": source, "loudness": measured, "center": round(center, 3)}


# ------------------------------------------------------------------------------------------------------------------- edit jobs: B-roll, beat sync, hook first
def plan_cuts(clips: list[dict], beat_times: list[float], beats_per_cut: int | None, max_seconds: float, hook_first: bool = True,
              default_cut: float = 2.0) -> list[dict]:
    """Segments [{clip, start, dur}] that fill max_seconds. With beats, every cut lands on a beat (beats_per_cut beats per shot); without, default_cut.
    hook_first puts the clip with the highest motion score first. Clips are used round-robin; each segment advances through its clip."""
    if not clips:
        raise MediaError("an edit needs at least one input clip")
    order = sorted(range(len(clips)), key=lambda i: -float(clips[i].get("score") or 0)) if hook_first else list(range(len(clips)))
    bounds = []
    if beat_times and beats_per_cut:
        bt = [t for t in beat_times if 0.25 <= t <= max_seconds + 0.01]
        marks = [0.0] + [t for i, t in enumerate(bt) if (i + 1) % beats_per_cut == 0]   # every cut, and the end, lands on a beat
        bounds = [(a, b) for a, b in zip(marks, marks[1:]) if b - a >= 0.25]
    if not bounds:
        t, bounds = 0.0, []
        while t < max_seconds - 0.25:
            bounds.append((t, min(t + default_cut, max_seconds)))
            t += default_cut
    pos = {i: 0.0 for i in range(len(clips))}
    segs = []
    for k, (a, b) in enumerate(bounds):
        ci = order[k % len(order)]
        d = round(b - a, 3)
        dur_c = float(clips[ci]["duration"])
        st = pos[ci] if pos[ci] + d <= dur_c else 0.0
        d = min(d, dur_c)
        segs.append({"clip": ci, "start": round(st, 3), "dur": round(d, 3), "at": round(a, 3)})
        pos[ci] = st + d
    return segs


def stitch(clips: list[dict], segs: list[dict], platform: str, out: str, *, music: str | None = None, fit: str = "auto_reframe",
           crossfade: float = 0.0, pad_colour: str = "black", workdir: str | None = None) -> dict:
    """B-roll stitch: each segment trimmed and fitted to the platform frame, joined by hard cuts (or crossfades), with the music bed (or the clips' own
    audio) under it. Produces an intermediate H.264 file; finish() adds captions, the label and loudness afterwards."""
    w, h = PLATFORMS[platform]
    tmp = workdir or tempfile.mkdtemp(prefix="cs-stitch-")
    parts = []
    centers = {}
    for k, s in enumerate(segs):
        c = clips[s["clip"]]
        if s["clip"] not in centers:
            centers[s["clip"]] = subject_center(c["path"]) if fit == "auto_reframe" else 0.5
        vf = fit_filter(c["width"], c["height"], platform, fit, centers[s["clip"]], pad_colour)
        p = os.path.join(tmp, f"seg{k:03d}.mp4")
        a_in = ["-f", "lavfi", "-t", str(s["dur"]), "-i", "anullsrc=r=48000:cl=stereo"] if not c.get("audio") else []
        amap = ["-map", "1:a"] if a_in else ["-map", "0:a"]
        ff(["-ss", str(s["start"]), "-t", str(s["dur"]), "-i", c["path"], *a_in, "-map", "0:v", *amap, "-vf", f"{vf},fps=30,format=yuv420p",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-c:a", "aac", "-ar", "48000", "-ac", "2", "-shortest", p])
        parts.append((p, s["dur"]))
    total = round(sum(d for _, d in parts) - crossfade * max(0, len(parts) - 1), 3)
    joined = os.path.join(tmp, "joined.mp4")
    if crossfade > 0 and len(parts) > 1:
        ins, fc, last, off = [], [], "[0:v]", 0.0
        for i, (p, d) in enumerate(parts):
            ins += ["-i", p]
        for i in range(1, len(parts)):
            off += parts[i - 1][1] - crossfade
            fc.append(f"{last}[{i}:v]xfade=transition=fade:duration={crossfade}:offset={round(off, 3)}[v{i}]")
            last = f"[v{i}]"
        alist = "".join(f"[{i}:a]" for i in range(len(parts)))
        fc.append(f"{alist}concat=n={len(parts)}:v=0:a=1[a]")
        ff([*ins, "-filter_complex", ";".join(fc), "-map", last, "-map", "[a]", "-t", str(total), "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-c:a", "aac", joined])
    else:
        lst = os.path.join(tmp, "list.txt")
        with open(lst, "w") as f:
            f.writelines(f"file '{p}'\n" for p, _ in parts)
        ff(["-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", joined])
    if music:
        final = out
        ff(["-i", joined, "-i", music, "-map", "0:v", "-map", "1:a", "-t", str(total), "-c:v", "copy", "-c:a", "aac", "-shortest", final])
    else:
        shutil.copyfile(joined, out)
    return {"segments": len(parts), "seconds": total}


def visualizer(audio: str, platform: str, out: str, *, kind: str = "waves", cover: str | None = None, colour: str = "#F4C430",
               seconds: float | None = None) -> str:
    """Music visualizer video: the cover art (or a dark background) with ffmpeg showwaves (waves) or showspectrum (spectrum) over the lower third.
    The audio is split inside the graph so the background never waits on a second decoder (bounded memory)."""
    w, h = PLATFORMS[platform]
    col = colour if re.fullmatch(r"#[0-9A-Fa-f]{6}", colour or "") else "#F4C430"
    vh = h // 4
    viz = (f"[a1]showwaves=s={w}x{vh}:mode=cline:rate=30:colors={col.replace('#', '0x')},format=yuva420p[viz]" if kind == "waves" else
           f"[a1]showspectrum=s={w}x{vh}:slide=scroll:mode=combined:color=intensity:fps=30,format=yuva420p[viz]")
    d = round(min(seconds or 1e9, probe(audio)["duration"] or 0), 3)
    if d <= 0:
        raise MediaError("the audio is empty")
    bg = ["-loop", "1", "-framerate", "30", "-t", str(d), "-i", cover] if cover else ["-f", "lavfi", "-i", f"color=c=0x111111:s={w}x{h}:r=30:d={d}"]
    fc = (f"[1:a]asplit[a1][aout];[0:v]scale={w}:{h}:force_original_aspect_ratio=increase,crop={w}:{h},setsar=1,fps=30[bg];{viz};"
          f"[bg][viz]overlay=0:H-h-{int(h * 0.12)}:shortest=1[v]")
    ff([*bg, "-i", audio, "-filter_complex", fc, "-map", "[v]", "-map", "[aout]", "-t", str(d), "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
        "-c:a", "aac", out], timeout=1200)
    return out
