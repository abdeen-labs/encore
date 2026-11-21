"""Wire format, structured errors and the stdout lock."""

import json
import math
import os
import sys
import threading

_out = None
_out_lock = threading.Lock()


def take_over_stdout() -> None:
    """Keeps a private handle on the real stdout for protocol messages and points file descriptor 1
    (Python prints, C libraries, tqdm…) at stderr, so stray output can never corrupt the stream."""
    global _out
    if _out is not None:
        return
    fd = os.dup(1)
    os.dup2(2, 1)
    _out = os.fdopen(fd, "w", buffering=1, encoding="utf-8", newline="\n")
    sys.stdout = sys.stderr


def _clean(value):
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if isinstance(value, dict):
        return {k: _clean(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_clean(v) for v in value]
    return value


def send(message: dict) -> None:
    line = json.dumps(_clean(message), ensure_ascii=False, separators=(",", ":"))
    with _out_lock:
        try:
            _out.write(line + "\n")
            _out.flush()
        except (BrokenPipeError, ValueError):
            os._exit(0)  # The app is gone.


def log(*parts) -> None:
    print("[encore-helper]", *parts, file=sys.stderr, flush=True)


class HelperError(Exception):
    """An error the app can show. `code` is stable; `message` is written for a person."""

    def __init__(self, code: str, message: str, detail: str | None = None):
        super().__init__(message)
        self.code, self.message, self.detail = code, message, detail

    def payload(self) -> dict:
        return {"code": self.code, "message": self.message, "detail": self.detail}


class JobCanceled(BaseException):
    """Raised inside a job when the app cancels it. BaseException so model code that catches
    `Exception` can't swallow it."""
