"""Speech-to-speech voice conversion with Chatterbox's S3 path.

The source speech is turned into S3 speech tokens (25 per second: what is said and its timing), and
Chatterbox's S3Gen decoder — flow matching to a mel spectrogram, then the HiFT vocoder — renders those
tokens in the target speaker's voice, conditioned on up to 10 s of reference audio. Output is 24 kHz.

Long sources are cut at the quietest point near each chunk limit and converted chunk by chunk with the
same conditioning; each chunk is trimmed/padded to its exact source length, so timing is preserved.
"""

import os

import numpy as np

from .audio import read_mono, write_wav_float32
from .protocol import HelperError

SOURCE_SR = 16000
OUTPUT_SR = 24000
MAX_CHUNK_SECONDS = 25.0
MIN_CHUNK_SECONDS = 8.0
REFERENCE_SECONDS = 10  # what S3Gen conditions on (Chatterbox's DEC_COND_LEN)
DEFAULT_STEPS = 10
DEFAULT_CFG_RATE = 0.7


def split_points(audio: np.ndarray, sr: int, max_s: float = MAX_CHUNK_SECONDS, min_s: float = MIN_CHUNK_SECONDS):
    """(start, end) sample ranges no longer than max_s, cut at the quietest 20 ms frame in the back part
    of each window."""
    n, hop = audio.size, sr // 50
    if n <= max_s * sr:
        return [(0, n)]
    frames = audio[: n - n % hop].reshape(-1, hop) if n >= hop else audio.reshape(1, -1)
    energy = np.sqrt(np.mean(frames.astype(np.float64) ** 2, axis=1) + 1e-12)
    # Smooth over ~100 ms so a cut lands inside a pause, not between two syllables.
    energy = np.convolve(energy, np.ones(5) / 5, mode="same")
    ranges, start = [], 0
    while n - start > max_s * sr:
        lo = (start + int(min_s * sr)) // hop
        hi = (start + int(max_s * sr)) // hop
        window = energy[lo:hi]
        # The latest frame that's about as quiet as the quietest one: long chunks give S3Gen more context.
        quiet = window.min() + 0.05 * (np.median(window) - window.min())
        cut = (lo + int(np.nonzero(window <= quiet)[0][-1])) * hop + hop // 2
        ranges.append((start, cut))
        start = cut
    ranges.append((start, n))
    return ranges


class ChatterboxVoiceConverter:
    def __init__(self, model):
        self.model = model
        self._conditionals = {}  # (path, mtime, size) → S3Gen reference dict

    def reference(self, path: str):
        try:
            st = os.stat(path)
        except OSError as e:
            raise HelperError("invalid_input", "The target voice's reference audio doesn't exist.", path) from e
        key = (path, st.st_mtime_ns, st.st_size)
        if key not in self._conditionals:
            import mlx.core as mx
            from mlx_audio.tts.models.chatterbox.s3tokenizer import log_mel_spectrogram

            # The S3Gen half of Chatterbox's prepare_conditionals: speaker x-vector, prompt mel and prompt
            # tokens from up to 10 s of reference. (The T3/voice-encoder half is for TTS and isn't loaded.)
            ref24 = read_mono(path, OUTPUT_SR)[: REFERENCE_SECONDS * OUTPUT_SR]
            if ref24.size < OUTPUT_SR:
                raise HelperError("invalid_input", "The target voice's reference audio is too short (under a second).")
            ref16 = read_mono(path, SOURCE_SR)[: REFERENCE_SECONDS * SOURCE_SR]
            mel = log_mel_spectrogram(mx.array(ref16))[None]
            tokens, lengths = self.model._s3_tokenizer(mel, mx.array([mel.shape[2]]))
            gen = self.model.s3gen.embed_ref(ref_wav=mx.array(ref24)[None], ref_sr=OUTPUT_SR,
                                             ref_speech_tokens=tokens, ref_speech_token_lens=lengths)
            mx.eval(*[v for v in gen.values() if isinstance(v, mx.array)])
            self._conditionals.clear()  # keep one; a reference takes well under a second to prepare
            self._conditionals[key] = gen
        return self._conditionals[key]

    def convert(self, req: dict, job) -> dict:
        import mlx.core as mx
        from mlx_audio.tts.models.chatterbox.s3tokenizer import log_mel_spectrogram

        target = (req.get("target") or {}).get("reference_audio")
        if not target:
            raise HelperError("invalid_input", "Voice conversion needs a target voice with reference audio.")
        params = dict(req.get("params") or {})
        steps = int(params.pop("n_timesteps", DEFAULT_STEPS))
        cfg_rate = float(params.pop("cfg_rate", DEFAULT_CFG_RATE))
        if not 1 <= steps <= 100:
            raise HelperError("invalid_input", "Flow-matching steps must be between 1 and 100.")
        ignored = sorted(params)

        job.progress(0.0, "Preparing the target voice")
        ref_dict = self.reference(target)
        source = read_mono(req["source_path"], SOURCE_SR)
        ranges = split_points(source, SOURCE_SR)

        s3gen = self.model.s3gen
        old_steps, old_cfg = s3gen.flow.n_timesteps, s3gen.flow.decoder.inference_cfg_rate
        s3gen.flow.n_timesteps, s3gen.flow.decoder.inference_cfg_rate = steps, cfg_rate
        parts = []
        try:
            for i, (a, b) in enumerate(ranges):
                job.check()
                job.progress(i / len(ranges), f"Converting {i + 1} of {len(ranges)}" if len(ranges) > 1 else "Converting")
                chunk = mx.array(source[a:b])
                mel = log_mel_spectrogram(chunk)[None]
                tokens, _ = self.model._s3_tokenizer(mel, mx.array([mel.shape[2]]))
                wav = s3gen(speech_tokens=tokens, ref_dict=ref_dict, finalize=True)
                mx.eval(wav)
                out = np.array(wav, dtype=np.float32).reshape(-1)  # a writable copy
                expected = (b - a) * OUTPUT_SR // SOURCE_SR
                out = out[:expected] if out.size >= expected else np.pad(out, (0, expected - out.size))
                if len(ranges) > 1:  # 10 ms fade at the cut so chunk joins don't click
                    fade = min(OUTPUT_SR // 100, out.size)
                    out[-fade:] *= np.linspace(1.0, 0.0, fade, dtype=np.float32)
                parts.append(out)
                del wav, tokens, mel, chunk
        finally:
            s3gen.flow.n_timesteps, s3gen.flow.decoder.inference_cfg_rate = old_steps, old_cfg

        audio = np.concatenate(parts)
        peak = float(np.max(np.abs(audio))) if audio.size else 0.0
        if peak > 0.999:  # the vocoder can overshoot; avoid hard clipping
            audio *= 0.999 / peak
        write_wav_float32(req["output_path"], audio, OUTPUT_SR)
        job.progress(1.0, "Converted")
        return {"path": req["output_path"], "sample_rate": OUTPUT_SR, "samples": int(audio.size),
                "duration": audio.size / OUTPUT_SR, "chunks": len(ranges), "ignored": ignored}
