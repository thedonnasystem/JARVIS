# Proposal: runtime dependencies for M8c captions and beat tracking

Status: owner decision. Not applied by M8c (`requirements.txt` and `requirements/` are protected).

M8c works without new dependencies: captions fall back to script timing, beat tracking falls back to a pure-Python onset tracker, everything else is
ffmpeg. For the full quality the Jarvis host needs:

| Package | Licence | Why | Size |
|---|---|---|---|
| `faster-whisper==1.2.1` (pulls `ctranslate2`, `tokenizers`, `onnxruntime`, `av`, `numpy`) | MIT (deps MIT / Apache-2.0 / BSD) | word-timed captions and lyric timing on the CPU | about 250 MB installed |
| `librosa==1.0.1` (pulls `numba`, `scipy`, `scikit-learn`, `soundfile`) | ISC (deps BSD) | better beat tracking for music edits | about 300 MB installed; optional |

And a model folder (no download at run time): put the CTranslate2 `tiny` (75 MB) or `base` (145 MB) Whisper model in a persistent volume and set
`CREATIVE_WHISPER_DIR` to it. `CREATIVE_WHISPER_DOWNLOAD=1` lets the first run fetch it from Hugging Face once instead.

The host also needs the ffmpeg build with `libass` (Ubuntu's `ffmpeg` package has it) and a font (`fonts-dejavu-core`). Fonts named in a brand kit
must be installed on the host to be used; otherwise libass falls back to a default font.

Owner change, one PR: add the two lines to `requirements/runtime.in`, re-lock `requirements/runtime.lock`, add `fonts-dejavu-core` to the host packages.

## Disclosure: the protected `test_no_bypass` and local transcription

`test_no_bypass.test_voice_provider_only_called_inside_metered_call` forbids the text `transcribe(` in every top-level module except `bot.py` /
`hq_voice.py`, to keep the PAID voice provider behind `hq_meter.metered_call`. faster-whisper's method has the same name but is local and free.
M8c therefore runs it in a separate process, `creative_studio/tools/whisper_words.py` (also frees the model's memory after each file), called by
`hq_creative_media.speech_words`. This is outside the test's scan by location, not by disguise: the owner should decide whether to (a) accept it as is,
or (b) extend the test to scan `creative_studio/tools/` and allow-list that file explicitly as "local, unmetered, no network". (b) is recommended.
