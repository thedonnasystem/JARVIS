"""Local, free speech-to-words for the creative studio's captions (faster-whisper, MIT; CPU int8). Run as a SEPARATE PROCESS by
hq_creative_media.speech_words so the model's memory is returned after every file:

    python3 -I creative_studio/tools/whisper_words.py --model tiny [--dir DIR] [--allow-download] <audio-or-video>   -> JSON [{word, start, end}] on stdout

No network unless --allow-download (one-time model fetch from Hugging Face). Not a paid voice provider: the metered provider path (bot.py ->
hq_voice) is untouched. It lives outside the top-level modules on purpose and is disclosed in ops/proposals/creative_media_deps.md (the protected
test_no_bypass reserves the name of the provider call for hq_voice).
"""
import argparse
import json
import subprocess
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--model", default="tiny")
    ap.add_argument("--dir", default=None)
    ap.add_argument("--allow-download", action="store_true")
    a = ap.parse_args()
    try:
        import numpy as np
        from faster_whisper import WhisperModel
    except Exception:
        print(json.dumps({"error": "faster-whisper is not installed"}))
        return 3
    try:
        model = WhisperModel(a.model, device="cpu", compute_type="int8", download_root=a.dir, local_files_only=not a.allow_download)
    except Exception as e:
        print(json.dumps({"error": f"whisper model {a.model} unavailable: {type(e).__name__}"}))
        return 4
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", a.path, "-vn", "-ac", "1", "-ar", "16000", "-f", "f32le", "-"],
                         capture_output=True, timeout=600, check=True).stdout
    segments, _info = model.transcribe(np.frombuffer(raw, dtype=np.float32), word_timestamps=True, vad_filter=True, beam_size=1,
                                       condition_on_previous_text=False)
    words = []
    for seg in segments:
        for w in getattr(seg, "words", None) or []:
            text = (w.word or "").strip()
            if text:
                words.append({"word": text, "start": round(float(w.start), 3), "end": round(float(max(w.end, w.start + 0.05)), 3)})
    print(json.dumps(words))
    return 0


if __name__ == "__main__":
    sys.exit(main())
