"""Loads models only from the snapshot directories the app hands over.

Some mlx-audio loaders fetch companion repos themselves (Chatterbox pulls S3TokenizerV2, Whisper may
pull a processor). While a model loads, `snapshot_download` / `hf_hub_download` are redirected to the
app-provided directories; anything else is resolved from the local cache only (HF_HUB_OFFLINE=1 is set
by the app too), so the helper never downloads on its own.
"""

import contextlib
import os
import sys
from pathlib import Path

from .protocol import HelperError


@contextlib.contextmanager
def local_repos(repo_dirs: dict[str, str]):
    import huggingface_hub

    original_snapshot = huggingface_hub.snapshot_download
    original_file = huggingface_hub.hf_hub_download
    dirs = {repo: Path(path) for repo, path in repo_dirs.items()}

    def snapshot_download(repo_id, *args, **kwargs):
        if repo_id in dirs:
            return str(dirs[repo_id])
        kwargs["local_files_only"] = True
        try:
            return original_snapshot(repo_id, *args, **kwargs)
        except Exception as e:
            raise HelperError("model_files_missing",
                              f"The model needs files from {repo_id}, which aren't downloaded.", str(e)) from e

    def hf_hub_download(repo_id, filename, *args, subfolder=None, **kwargs):
        if repo_id in dirs:
            path = dirs[repo_id] / (subfolder or "") / filename
            if path.exists():
                return str(path)
            raise HelperError("model_files_missing", f"{filename} is missing from the downloaded {repo_id}.")
        kwargs["local_files_only"] = True
        try:
            return original_file(repo_id, filename, *args, subfolder=subfolder, **kwargs)
        except Exception as e:
            raise HelperError("model_files_missing",
                              f"The model needs {filename} from {repo_id}, which isn't downloaded.", str(e)) from e

    patched = []
    for name, module in list(sys.modules.items()):
        if module is None or not name.startswith(("mlx_audio", "transformers", "huggingface_hub")):
            continue
        for attr, original, replacement in (("snapshot_download", original_snapshot, snapshot_download),
                                            ("hf_hub_download", original_file, hf_hub_download)):
            if getattr(module, attr, None) is original:
                setattr(module, attr, replacement)
                patched.append((module, attr, original))
    try:
        yield
    finally:
        for module, attr, original in patched:
            setattr(module, attr, original)
        # Modules first imported during the load bound the replacements at import time; undo those too.
        for module in list(sys.modules.values()):
            for attr, original, replacement in (("snapshot_download", original_snapshot, snapshot_download),
                                                ("hf_hub_download", original_file, hf_hub_download)):
                if getattr(module, attr, None) is replacement:
                    setattr(module, attr, original)


def check_dirs(repo_dirs: dict[str, str], primary: str) -> Path:
    if primary not in repo_dirs:
        raise HelperError("bad_request", f"No local directory was given for {primary}.")
    for repo, path in repo_dirs.items():
        if not os.path.isdir(path):
            raise HelperError("model_files_missing", f"{repo} isn't downloaded (missing {path}).")
    root = Path(repo_dirs[primary])
    if not (root / "config.json").exists():
        raise HelperError("model_files_missing", f"{primary} is incomplete: config.json is missing.")
    return root
