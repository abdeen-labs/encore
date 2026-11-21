"""Encore's Python helper: a long-lived worker that runs mlx-audio models for the app.

Protocol: one JSON object per line. Swift writes requests to stdin; the helper writes replies and
events to stdout (and nothing else — logs go to stderr).

  request  {"id": 7, "op": "synthesize", ...}
  reply    {"id": 7, "ok": true, "result": {...}}
           {"id": 7, "ok": false, "error": {"code": "...", "message": "...", "detail": "..."}}
  event    {"id": 7, "event": "progress", "fraction": 0.4, "stage": "Converting 2 of 5"}

Ops: hello, load, unload, list, memory, synthesize, transcribe, convert_voice, cancel, shutdown.
Jobs run one at a time in arrival order; hello, list, memory, cancel and shutdown are answered
immediately, even while a job runs.
"""

PROTOCOL_VERSION = 1
HELPER_VERSION = "0.1.0"
