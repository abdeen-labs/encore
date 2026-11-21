"""Reading and writing audio files for the app."""

import os
import struct

import numpy as np

from .protocol import HelperError


def read_mono(path: str, sample_rate: int) -> np.ndarray:
    """Any format mlx-audio can decode (WAV/MP3/M4A/FLAC…, more with ffmpeg on PATH) → mono float32."""
    if not os.path.isfile(path):
        raise HelperError("invalid_input", f"The audio file {os.path.basename(path)} doesn't exist.", path)
    from mlx_audio.audio_io import read

    try:
        audio, _ = read(path, dtype="float32", sample_rate=sample_rate, nchannels=1)
    except Exception as e:
        raise HelperError("invalid_input", f"Couldn't read the audio file {os.path.basename(path)}.", str(e)) from e
    audio = np.asarray(audio, dtype=np.float32).reshape(-1)
    if audio.size == 0:
        raise HelperError("invalid_input", f"The audio file {os.path.basename(path)} is empty.")
    return audio


def write_wav_float32(path: str, samples: np.ndarray, sample_rate: int) -> None:
    """Mono 32-bit float WAV (WAVE_FORMAT_IEEE_FLOAT). Written to a temp name, then moved into place."""
    data = np.ascontiguousarray(samples, dtype="<f4").tobytes()
    header = b"RIFF" + struct.pack("<I", 4 + 26 + 12 + 8 + len(data)) + b"WAVE"
    fmt = b"fmt " + struct.pack("<IHHIIHHH", 18, 3, 1, sample_rate, sample_rate * 4, 4, 32, 0)
    fact = b"fact" + struct.pack("<II", 4, len(samples))
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(header + fmt + fact + b"data" + struct.pack("<I", len(data)) + data)
    os.replace(tmp, path)


def to_numpy(audio) -> np.ndarray:
    return np.asarray(audio, dtype=np.float32).reshape(-1)
