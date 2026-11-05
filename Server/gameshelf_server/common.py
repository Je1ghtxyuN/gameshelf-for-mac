"""Shared authority locking, API errors and bounded text validation."""
import functools
import json

class APIError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message
        super().__init__(message)

def locked(fn):
    @functools.wraps(fn)
    def call(self, *args, **kwargs):
        with self.lock:
            return fn(self, *args, **kwargs)
    return call

def text(value, maximum=256):
    if not isinstance(value, str) or not value or len(value) > maximum or any(ord(c) < 32 for c in value):
        raise APIError(400, 'Invalid text')
    return value


def wire_json(value):
    """One encoding for HTTP responses and exact response-byte accounting."""
    return json.dumps(value,ensure_ascii=False,allow_nan=False).encode("utf-8")
