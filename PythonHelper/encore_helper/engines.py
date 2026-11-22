"""Engine keys (ModelManifest.engine) → how the helper loads and runs them.

Manifest parameter keys are mlx-audio's own keyword names. mlx-audio swallows unknown keywords
silently, so each call passes a model only the keywords its `generate` actually declares, and reports
the rest back as `ignored`.
"""

import importlib.util
import inspect
import os
import re
import time
from dataclasses import dataclass, field

import numpy as np

from .audio import to_numpy, write_wav_float32
from .protocol import HelperError

# Feature names match Swift's EngineFeatures.
SYNTH, CLONE, DESIGN = "synthesis", "cloning", "voiceDesign"
STT, WORDS, VC = "transcription", "wordTimestamps", "voiceConversion"


@dataclass(frozen=True)
class EngineSpec:
    kind: str  # "tts", "stt" or "vc"
    module: str  # mlx-audio package path that must exist, relative to mlx_audio/
    features: tuple
    needs: tuple = ()  # extra importable modules
    note: str = ""


ENGINES = {
    "qwen3_tts": EngineSpec("tts", "tts/models/qwen3_tts", (SYNTH, CLONE, DESIGN)),
    "chatterbox": EngineSpec("tts", "tts/models/chatterbox", (SYNTH, CLONE)),
    "chatterbox_turbo": EngineSpec("tts", "tts/models/chatterbox_turbo", (SYNTH, CLONE)),
    "voxcpm2": EngineSpec("tts", "tts/models/voxcpm2", (SYNTH, CLONE, DESIGN)),
    "omnivoice": EngineSpec("tts", "tts/models/omnivoice", (SYNTH, CLONE, DESIGN)),
    "llama": EngineSpec("tts", "tts/models/llama", (SYNTH,)),  # Orpheus
    "dia": EngineSpec("tts", "tts/models/dia", (SYNTH, CLONE)),
    "zonos3": EngineSpec("tts", "tts/models/zonos3", (SYNTH, CLONE)),
    "soprano": EngineSpec("tts", "tts/models/soprano", (SYNTH,)),
    "pocket_tts": EngineSpec("tts", "tts/models/pocket_tts", (SYNTH, CLONE)),
    "whisper": EngineSpec("stt", "stt/models/whisper", (STT, WORDS)),
    "parakeet": EngineSpec("stt", "stt/models/parakeet", (STT,)),
    "chatterbox_vc": EngineSpec("vc", "tts/models/chatterbox", (VC,)),
}


def available_engines() -> tuple[dict, dict]:
    """Engine key → features this install supports, and engine key → why it's missing. Doesn't import mlx."""
    spec = importlib.util.find_spec("mlx_audio")
    root = spec.submodule_search_locations[0] if spec and spec.submodule_search_locations else None
    supported, missing = {}, {}
    for key, e in ENGINES.items():
        if root is None or not os.path.isdir(os.path.join(root, e.module)):
            missing[key] = "This mlx-audio version doesn't include it."
        elif any(importlib.util.find_spec(m) is None for m in e.needs):
            missing[key] = e.note or f"Needs Python packages that aren't installed: {', '.join(e.needs)}."
        else:
            supported[key] = list(e.features)
    return supported, missing


def spec_for(engine: str) -> EngineSpec:
    e = ENGINES.get(engine)
    if e is None:
        raise HelperError("unsupported_engine", f"The Python helper doesn't know the engine “{engine}”.")
    supported, missing = available_engines()
    if engine in missing:
        raise HelperError("unsupported_engine", missing[engine])
    return e


@dataclass
class LoadedModel:
    model_id: str
    engine: str
    kind: str
    path: str
    module: object
    loaded_at: float = field(default_factory=time.time)
    extra: dict = field(default_factory=dict)


def load_module(kind: str, path: str, lazy: bool = False):
    """Builds the mlx-audio model from a local snapshot directory. With `lazy`, weights stay unmaterialized
    until the caller evaluates them (so parts it doesn't need never take memory)."""
    if kind == "stt":
        from mlx_audio.stt.utils import load
    else:
        from mlx_audio.tts.utils import load
    try:
        return load(path, lazy=lazy)
    except HelperError:
        raise
    except FileNotFoundError as e:
        raise HelperError("model_files_missing", "Some of the model's files are missing. Try downloading it again.",
                          str(e)) from e
    except MemoryError as e:
        raise HelperError("out_of_memory", "There isn't enough memory to load this model.", str(e)) from e
    except Exception as e:
        raise HelperError("load_failed", "The model couldn't be loaded.", f"{type(e).__name__}: {e}") from e


# MARK: - Text to speech

_KWARGS_READ = re.compile(r"""kwargs(?:\.get|\.pop|\[)\(?\s*["']([A-Za-z_][A-Za-z0-9_]*)["']""")


def _generate_params(model) -> set:
    """Keyword names `generate` really uses: its declared parameters, plus names it (or its module) reads
    out of `**kwargs` — e.g. Orpheus takes repetition_penalty via kwargs.get."""
    params = inspect.signature(model.generate).parameters
    names = {k for k, p in params.items() if p.kind not in (p.VAR_KEYWORD, p.VAR_POSITIONAL)}
    if any(p.kind == p.VAR_KEYWORD for p in params.values()):
        try:
            names |= set(_KWARGS_READ.findall(inspect.getsource(inspect.getmodule(type(model)))))
        except (OSError, TypeError):
            pass
    return names


# Keys Encore never forwards from manifest parameters: they're set from the job itself, or would change
# the shape of what generate returns.
_RESERVED = {"text", "voice", "ref_audio", "ref_text", "instruct", "lang_code", "language", "stream",
             "verbose", "audio_prompt", "conds", "tokenizer", "text_tokenizer", "input_ids", "ref_tokens"}


# Scripts written without spaces between words (Thai/Lao, Tibetan, Myanmar, Khmer, CJK, kana, fullwidth forms).
_NO_SPACE_RANGES = ((0x0E00, 0x0FFF), (0x1000, 0x109F), (0x1780, 0x17FF), (0x2E80, 0x312F), (0x31A0, 0x9FFF),
                    (0xF900, 0xFAFF), (0xFF00, 0xFFEF), (0x20000, 0x3FFFF))


def _no_space(ch: str) -> bool:
    return any(lo <= ord(ch) <= hi for lo, hi in _NO_SPACE_RANGES)


def _join_prompt(transcript: str, text: str) -> str:
    """The prompt transcript, ready to run into the script: a space between them, unless either side of the join
    is a script written without spaces, where a space doesn't belong."""
    first = text.lstrip()[:1]
    if _no_space(transcript[-1]) or (first and _no_space(first)):
        return transcript
    return transcript + " "


def synthesize(loaded: LoadedModel, req: dict, job) -> dict:
    model = loaded.module
    accepted = _generate_params(model)
    kwargs, ignored = {"text": req["text"]}, []

    def put(key, value) -> bool:
        if value is None or value == "":
            return False
        if key in accepted:
            kwargs[key] = value
            return True
        return False

    voice = req.get("voice") or {}
    if voice.get("preset") and not put("voice", voice["preset"]):
        ignored.append("voice")
    if voice.get("reference_audio"):
        if not os.path.isfile(voice["reference_audio"]):
            raise HelperError("invalid_input", "The reference audio file doesn't exist.", voice["reference_audio"])
        if not put("ref_audio", voice["reference_audio"]):
            raise HelperError("unsupported", f"{loaded.engine} can't clone from reference audio.")
        transcript = (voice.get("reference_text") or "").strip()
        if transcript and {"prompt_audio", "prompt_text"} <= accepted:
            # VoxCPM: ref_audio alone clones only the timbre, and its ref_text is accepted but never read. Giving
            # the same clip and its transcript as the prompt too makes the model continue from it, which keeps the
            # accent and delivery. The prompt text runs straight into the script, so it needs a separator.
            put("prompt_audio", voice["reference_audio"])
            put("prompt_text", _join_prompt(transcript, req["text"]))
        elif transcript and not put("ref_text", transcript):
            ignored.append("ref_text")
    if req.get("instruct") and not put("instruct", req["instruct"]):
        ignored.append("instruct")
    language = req.get("language")
    if language:
        used = put("lang_code", language)
        used = put("language", language) or used
        if not used:
            ignored.append("language")

    params = dict(req.get("params") or {})
    seed = params.pop("seed", None)
    # OmniVoice: a length of 0 means "work it out", as in the native port. mlx-audio would make 0 s of audio.
    if params.get("duration_s") is not None and float(params["duration_s"]) <= 0:
        del params["duration_s"]
    for key, value in params.items():
        if key in _RESERVED or not put(key, value):
            ignored.append(key)
    if seed is not None:
        import mlx.core as mx

        mx.random.seed(int(seed))
        put("seed", int(seed))
    put("verbose", False)
    if "stream" in accepted:
        kwargs["stream"] = False

    if "ref_audio" not in kwargs and loaded.engine == "chatterbox" and getattr(model, "_conds", None) is None:
        raise HelperError("invalid_input", "This Chatterbox checkpoint has no built-in voice. Choose a voice to clone.")

    job.progress(None, "Generating")
    pieces, sample_rate = [], None
    try:
        for i, result in enumerate(model.generate(**kwargs)):
            job.check()
            pieces.append(to_numpy(result.audio))
            sample_rate = sample_rate or getattr(result, "sample_rate", None)
            job.progress(None, f"Generated part {i + 1}")
    except (ValueError, KeyError) as e:  # mlx-audio reports bad input (unknown voice, language…) this way
        raise HelperError("generation_failed", f"The model couldn't generate this: {e}", f"{type(e).__name__}: {e}") from e
    sample_rate = int(sample_rate or getattr(model, "sample_rate", 24000))
    audio = np.concatenate(pieces) if pieces else np.zeros(0, dtype=np.float32)
    if audio.size == 0:
        raise HelperError("generation_failed", "The model produced no audio. Try different text or settings.")
    write_wav_float32(req["output_path"], audio, sample_rate)
    return {"path": req["output_path"], "sample_rate": sample_rate, "samples": int(audio.size),
            "duration": audio.size / sample_rate, "ignored": sorted(set(ignored))}


# MARK: - Speech to text

def _whisper_temperatures(start) -> tuple:
    """Whisper retries a passage at rising temperatures when it comes out repetitive or unsure; a single number
    turns that off. So the setting is where the retries start: 0 → (0, 0.2, …, 1.0), 0.4 → (0.4, 0.6, …, 1.0)."""
    start = min(max(float(start), 0.0), 1.0)
    steps = int(round((1.0 - start) / 0.2))
    return tuple(round(start + 0.2 * i, 2) for i in range(steps + 1)) or (start,)


def transcribe(loaded: LoadedModel, req: dict, job) -> dict:
    from .audio import read_mono

    model, path = loaded.module, req["audio_path"]
    audio = read_mono(path, 16000)  # validates the file; Whisper and Parakeet both work at 16 kHz
    duration = audio.size / 16000
    want_words = req.get("timestamps") == "word"
    params = dict(req.get("params") or {})
    accepted = _generate_params(model)
    kwargs = {k: v for k, v in params.items() if k in accepted and k not in _RESERVED}
    ignored = sorted(k for k in params if k not in kwargs)

    if loaded.engine == "whisper":
        import mlx.core as mx

        if req.get("language"):
            kwargs["language"] = req["language"]
        if "temperature" in kwargs:
            kwargs["temperature"] = _whisper_temperatures(kwargs["temperature"])
        kwargs["word_timestamps"] = want_words
        kwargs["verbose"] = False  # enables Whisper's progress bar, which job.track_tqdm turns into events
        with job.track_tqdm():
            out = model.generate(mx.array(audio), **kwargs)
        segments = []
        for i, s in enumerate(out.segments or []):
            words = None
            if want_words:
                words = [{"start": float(w["start"]), "end": float(w["end"]), "text": w["word"].strip()}
                         for w in s.get("words", []) if w.get("word", "").strip()]
            segments.append({"id": i, "start": float(s["start"]), "end": float(s["end"]),
                             "text": s["text"].strip(), "words": words})
        return {"text": (out.text or "").strip(), "language": out.language, "duration": duration,
                "segments": segments, "ignored": ignored}

    if loaded.engine == "parakeet":
        import mlx.core as mx

        def on_chunk(current, total):
            job.check()
            job.progress(current / total if total else None, "Transcribing")

        if "chunk_duration" not in kwargs and duration > 120:
            kwargs["chunk_duration"] = 120.0
        if "chunk_duration" in kwargs and "overlap_duration" in accepted:
            # mlx-audio's own overlap is 2 s, little to line the pieces up on. A quarter of a short chunk at most.
            kwargs["overlap_duration"] = min(15.0, float(kwargs["chunk_duration"]) / 4)
        if "chunk_callback" in accepted:
            kwargs["chunk_callback"] = on_chunk
        out = model.generate(mx.array(audio), **kwargs)
        segments = []
        for i, s in enumerate(out.sentences):
            words = _merge_subword_tokens(s.tokens) if want_words else None
            segments.append({"id": i, "start": float(s.start), "end": float(s.end), "text": s.text.strip(),
                             "words": words})
        return {"text": out.text, "language": req.get("language"), "duration": duration, "segments": segments,
                "ignored": ignored}

    raise HelperError("unsupported_engine", f"Transcription isn't wired up for {loaded.engine}.")


def _merge_subword_tokens(tokens) -> list:
    """Parakeet's SentencePiece tokens → words: a token that starts with a space starts a new word."""
    words = []
    for t in tokens:
        if not words or t.text.startswith(" "):
            words.append({"start": float(t.start), "end": float(t.end), "text": t.text.strip()})
        else:
            words[-1]["end"] = float(t.end)
            words[-1]["text"] += t.text
    return [w for w in words if w["text"]]
