"""The worker loop: a reader thread takes requests off stdin; jobs run one at a time on the main thread."""

import contextlib
import ctypes
import gc
import importlib.metadata
import json
import os
import platform
import queue
import resource
import sys
import threading
import time
import traceback

from . import HELPER_VERSION, PROTOCOL_VERSION
from .engines import LoadedModel, available_engines, load_module, spec_for, synthesize, transcribe
from .hub import check_dirs, local_repos
from .protocol import HelperError, JobCancelled, log, send

IMMEDIATE_OPS = {"hello", "list", "memory", "cancel", "shutdown"}
JOB_OPS = {"load", "unload", "synthesize", "transcribe", "convert_voice"}
_devnull = open(os.devnull, "w")


def _version(dist: str):
    try:
        return importlib.metadata.version(dist)
    except importlib.metadata.PackageNotFoundError:
        return None


def memory_stats() -> dict:
    stats = {"peak_rss": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}  # bytes on macOS
    mx = sys.modules.get("mlx.core")
    if mx is not None:
        stats.update(active=mx.get_active_memory(), cache=mx.get_cache_memory(), peak=mx.get_peak_memory())
    else:
        stats.update(active=0, cache=0, peak=0)
    return stats


def _release_memory() -> None:
    gc.collect()
    mx = sys.modules.get("mlx.core")
    if mx is not None:
        mx.clear_cache()


class Job:
    def __init__(self, request: dict):
        self.request = request
        self.id = request.get("id")
        self.cancelled = threading.Event()
        self._last_progress = 0.0

    def check(self) -> None:
        if self.cancelled.is_set():
            raise JobCancelled()

    def progress(self, fraction, stage=None) -> None:
        now = time.monotonic()
        if stage is None and fraction is not None and fraction < 1 and now - self._last_progress < 0.1:
            return
        self._last_progress = now
        send({"id": self.id, "event": "progress", "fraction": fraction, "stage": stage})

    @contextlib.contextmanager
    def track_tqdm(self):
        """Turns tqdm progress bars inside mlx-audio into progress events (and cancellation points)."""
        import tqdm as tqdm_module

        original, job = tqdm_module.tqdm, self

        class Tracked(original):
            def __init__(self, *args, **kwargs):
                kwargs["disable"], kwargs["file"] = False, _devnull
                super().__init__(*args, **kwargs)

            def update(self, n=1):
                result = super().update(n)
                job.check()
                if self.total:
                    job.progress(min(1.0, self.n / self.total))
                return result

        patched = [m for m in list(sys.modules.values()) if getattr(m, "tqdm", None) is original]
        tqdm_module.tqdm = Tracked
        for m in patched:
            m.tqdm = Tracked
        try:
            yield
        finally:
            tqdm_module.tqdm = original
            for m in patched:
                m.tqdm = original


class Worker:
    def __init__(self):
        self.models: dict[str, LoadedModel] = {}
        self.modules: dict[tuple, list] = {}  # (loader kind, path) → [module, refcount]
        self.jobs: queue.Queue = queue.Queue()
        self.lock = threading.Lock()
        self.current: Job | None = None
        self.cancelled_ids: set = set()
        self.main_thread_id = threading.get_ident()
        self.shutting_down = False

    # MARK: Immediate ops (reader thread)

    def hello(self, req) -> dict:
        supported, missing = available_engines()
        return {
            "protocol": PROTOCOL_VERSION, "helper": HELPER_VERSION, "pid": os.getpid(),
            "python": platform.python_version(), "executable": sys.executable,
            "packages": {d: _version(d) for d in ("mlx", "mlx-audio", "numpy", "transformers", "huggingface-hub")},
            "engines": supported, "unavailable": missing,
        }

    def list_models(self, req) -> dict:
        return {"models": [{"model_id": m.model_id, "engine": m.engine, "path": m.path, "loaded_at": m.loaded_at}
                           for m in list(self.models.values())]}

    def cancel(self, req) -> dict:
        target = req.get("target")
        with self.lock:
            job = self.current
            if job is not None and job.id == target:
                job.cancelled.set()
                # Interrupt Python code inside the model's generation loop, not only at our own checkpoints.
                ctypes.pythonapi.PyThreadState_SetAsyncExc(ctypes.c_ulong(self.main_thread_id),
                                                           ctypes.py_object(JobCancelled))
                return {"cancelled": "running"}
            self.cancelled_ids.add(target)
        return {"cancelled": "queued"}

    def shutdown(self, req) -> dict:
        self.shutting_down = True
        with self.lock:
            job = self.current
        if job is not None:
            self.cancel({"target": job.id})
        while True:  # queued jobs won't run
            try:
                queued = self.jobs.get_nowait()
            except queue.Empty:
                break
            if queued is not None:
                send({"id": queued.get("id"), "ok": False, "error": {"code": "cancelled", "message": "Cancelled."}})
        self.jobs.put(None)
        threading.Timer(5.0, lambda: os._exit(0)).start()  # don't wait forever on a stuck job
        return {}

    # MARK: Jobs (main thread)

    def load(self, job: Job) -> dict:
        req = job.request
        model_id, engine, repo = req["model_id"], req["engine"], req["repo"]
        spec = spec_for(engine)
        repo_dirs = req.get("repo_dirs") or {}
        root = str(check_dirs(repo_dirs, repo))
        existing = self.models.get(model_id)
        if existing is not None and existing.path == root and existing.engine == engine:
            return {"model_id": model_id, "already_loaded": True, "load_seconds": 0.0, "memory": memory_stats()}
        if existing is not None:
            self._drop(model_id)

        loader = "stt" if spec.kind == "stt" else "tts"
        # Modules are shared by (kind, directory). Voice conversion reuses a full Chatterbox that TTS already
        # loaded from the same checkpoint; otherwise it loads a pruned copy (S3 tokenizer + S3Gen only).
        key = (spec.kind, root)
        if spec.kind == "vc" and ("tts", root) in self.modules:
            key = ("tts", root)
        started = time.monotonic()
        job.progress(None, "Loading model")
        if key in self.modules:
            module = self.modules[key][0]
            self.modules[key][1] += 1
        else:
            import mlx_audio.stt.utils  # noqa: F401 — imported before patching so local_repos can redirect them
            import mlx_audio.tts.utils  # noqa: F401
            import mlx_audio.utils  # noqa: F401

            with local_repos(repo_dirs):
                module = load_module(loader, root, lazy=spec.kind == "vc")
            if spec.kind == "vc":
                # Drop the TTS-only T3 and voice encoder before their weights are ever materialised.
                import mlx.core as mx

                for part in ("t3", "ve"):
                    module.pop(part, None)
                mx.eval(module.parameters())
                _release_memory()
            self.modules[key] = [module, 1]
        loaded = LoadedModel(model_id, engine, spec.kind, root, module)
        loaded.extra["key"] = key
        if spec.kind == "vc":
            if not hasattr(module, "s3gen") or getattr(module, "_s3_tokenizer", None) is None:
                self._release_module(key)
                raise HelperError("load_failed", "This checkpoint has no S3Gen decoder or speech tokenizer.")
            self._attach_converter(loaded, module)
        elif key == ("tts", root) and ("vc", root) in self.modules:
            # A full Chatterbox is now resident: move voice conversion onto it and free the pruned copy.
            for other in self.models.values():
                if other.extra.get("key") == ("vc", root):
                    self._release_module(("vc", root))
                    self.modules[key][1] += 1
                    other.module, other.extra["key"] = module, key
                    self._attach_converter(other, module)
            _release_memory()
        self.models[model_id] = loaded
        return {"model_id": model_id, "already_loaded": False, "load_seconds": time.monotonic() - started,
                "sample_rate": getattr(module, "sample_rate", None), "shared": self.modules[key][1] > 1,
                "memory": memory_stats()}

    @staticmethod
    def _attach_converter(loaded: LoadedModel, module) -> None:
        from .voice_conversion import ChatterboxVoiceConverter

        loaded.extra["converter"] = ChatterboxVoiceConverter(module)

    def unload(self, job: Job) -> dict:
        model_id = job.request["model_id"]
        before = memory_stats()
        was_loaded = self._drop(model_id)
        _release_memory()
        return {"model_id": model_id, "was_loaded": was_loaded, "before": before, "after": memory_stats()}

    def _drop(self, model_id: str) -> bool:
        loaded = self.models.pop(model_id, None)
        if loaded is None:
            return False
        key = loaded.extra.get("key", (loaded.kind, loaded.path))
        module = loaded.module
        loaded.module = None
        loaded.extra.clear()
        self._release_module(key)
        users = [m for m in self.models.values() if m.extra.get("key") == key]
        if key[0] == "tts" and users and all(m.kind == "vc" for m in users):
            # Only voice conversion still uses this Chatterbox: free its TTS-only parts.
            for part in ("t3", "ve"):
                module.pop(part, None)
            vc_key = ("vc", key[1])
            self.modules[vc_key] = self.modules.pop(key)
            for m in users:
                m.extra["key"] = vc_key
        return True

    def _release_module(self, key) -> None:
        entry = self.modules.get(key)
        if entry is not None:
            entry[1] -= 1
            if entry[1] <= 0:
                del self.modules[key]

    def _model(self, model_id: str, kind: str) -> LoadedModel:
        loaded = self.models.get(model_id)
        if loaded is None:
            raise HelperError("model_not_loaded", f"The model {model_id} isn't loaded.")
        if loaded.kind != kind:
            raise HelperError("unsupported", f"The model {model_id} can't do that.")
        return loaded

    def synthesize(self, job: Job) -> dict:
        return synthesize(self._model(job.request["model_id"], "tts"), job.request, job)

    def transcribe(self, job: Job) -> dict:
        return transcribe(self._model(job.request["model_id"], "stt"), job.request, job)

    def convert_voice(self, job: Job) -> dict:
        loaded = self._model(job.request["model_id"], "vc")
        return loaded.extra["converter"].convert(job.request, job)

    # MARK: Loops

    def _finish(self) -> None:
        """Marks the job done and drops any cancellation injected too late to matter. Retries if that
        injection lands while we're in here."""
        while True:
            try:
                with self.lock:
                    self.current = None
                    ctypes.pythonapi.PyThreadState_SetAsyncExc(ctypes.c_ulong(self.main_thread_id), None)
                return
            except JobCancelled:
                continue

    def run_jobs(self) -> None:
        while True:
            request = self.jobs.get()
            if request is None:
                break
            job = Job(request)
            with self.lock:
                if job.id in self.cancelled_ids:
                    self.cancelled_ids.discard(job.id)
                    send({"id": job.id, "ok": False, "error": {"code": "cancelled", "message": "Cancelled."}})
                    continue
                self.current = job
            reply = None
            try:
                try:
                    result = getattr(self, request["op"])(job)
                    reply = {"id": job.id, "ok": True, "result": result}
                finally:
                    self._finish()
            except JobCancelled:
                self._finish()
                reply = {"id": job.id, "ok": False, "error": {"code": "cancelled", "message": "Cancelled."}}
            except HelperError as e:
                reply = {"id": job.id, "ok": False, "error": e.payload()}
            except KeyError as e:
                reply = {"id": job.id, "ok": False,
                         "error": {"code": "bad_request", "message": f"The request is missing {e}.", "detail": None}}
            except MemoryError as e:
                reply = {"id": job.id, "ok": False, "error": {"code": "out_of_memory", "detail": str(e),
                         "message": "There isn't enough memory for this. Close other apps or unload models."}}
            except Exception as e:  # noqa: BLE001 — everything else becomes a structured error
                text = f"{type(e).__name__}: {e}"
                log(traceback.format_exc())
                oom = "malloc" in text.lower() or "out of memory" in text.lower()
                reply = {"id": job.id, "ok": False, "error": {
                    "code": "out_of_memory" if oom else "internal",
                    "message": "There isn't enough memory for this." if oom else "The Python helper hit an error.",
                    "detail": text}}
            if request["op"] != "load":
                _release_memory()  # don't sit on MLX's buffer cache between jobs
            send(reply)
        log("shutting down")

    def read_requests(self) -> None:
        for raw in sys.stdin.buffer:
            try:
                request = json.loads(raw)
                op = request["op"]
            except (ValueError, KeyError, TypeError) as e:
                send({"id": None, "ok": False, "error": {"code": "bad_request", "message": "Unreadable request.",
                                                         "detail": str(e)}})
                continue
            if op in IMMEDIATE_OPS:
                handler = {"hello": self.hello, "list": self.list_models, "memory": lambda r: memory_stats(),
                           "cancel": self.cancel, "shutdown": self.shutdown}[op]
                try:
                    send({"id": request.get("id"), "ok": True, "result": handler(request)})
                except Exception as e:  # noqa: BLE001
                    send({"id": request.get("id"), "ok": False,
                          "error": {"code": "internal", "message": "The Python helper hit an error.", "detail": str(e)}})
                if op == "shutdown":
                    return
            elif op in JOB_OPS:
                if self.shutting_down:
                    send({"id": request.get("id"), "ok": False,
                          "error": {"code": "shutting_down", "message": "The Python helper is shutting down."}})
                else:
                    self.jobs.put(request)
            else:
                send({"id": request.get("id"), "ok": False,
                      "error": {"code": "unknown_op", "message": f"Unknown request “{op}”.", "detail": None}})
        # stdin closed: the app quit or died. Leave now, even mid-job.
        os._exit(0)


def _watch_parent() -> None:
    parent = os.getppid()
    while True:
        time.sleep(1.0)
        if os.getppid() != parent:  # re-parented to launchd: the app is gone
            os._exit(0)


def main() -> None:
    worker = Worker()
    threading.Thread(target=worker.read_requests, name="stdin", daemon=True).start()
    threading.Thread(target=_watch_parent, name="parent-watch", daemon=True).start()
    log(f"ready (pid {os.getpid()}, Python {platform.python_version()})")
    worker.run_jobs()
