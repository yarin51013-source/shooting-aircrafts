"""Joy of Painting local mouse helper.
Uses only Python's standard library plus Windows APIs. It accepts requests only
from the hosted Joy of Painting page and only on the local loopback interface.
"""
import ctypes
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from ctypes import wintypes

APP_ORIGIN = "https://joy-of-painting-guide.onrender.com"
HOST = "127.0.0.1"
PORT = 8765

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
WH_MOUSE_LL = 14
WM_LBUTTONDOWN = 0x0201
HC_ACTION = 0
LL = ctypes.c_long
ULONG_PTR = ctypes.c_size_t

class POINT(ctypes.Structure):
    _fields_ = [("x", wintypes.LONG), ("y", wintypes.LONG)]

class MSLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("pt", POINT), ("mouseData", wintypes.DWORD),
                ("flags", wintypes.DWORD), ("time", wintypes.DWORD),
                ("dwExtraInfo", ULONG_PTR)]

HOOKPROC = ctypes.WINFUNCTYPE(LL, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)
state_lock = threading.Lock()
state = {"armed": False, "click": None, "label": ""}
stopped = threading.Event()

user32.SetWindowsHookExW.argtypes = [ctypes.c_int, HOOKPROC, wintypes.HINSTANCE, wintypes.DWORD]
user32.SetWindowsHookExW.restype = wintypes.HANDLE
user32.CallNextHookEx.argtypes = [wintypes.HANDLE, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM]
user32.CallNextHookEx.restype = LL
user32.GetCursorPos.argtypes = [ctypes.POINTER(POINT)]
user32.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
user32.mouse_event.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, ULONG_PTR]
kernel32.GetModuleHandleW.argtypes = [wintypes.LPCWSTR]
kernel32.GetModuleHandleW.restype = wintypes.HMODULE
kernel32.GetLastError.restype = wintypes.DWORD

@HOOKPROC
def mouse_callback(n_code, w_param, l_param):
    if n_code == HC_ACTION and w_param == WM_LBUTTONDOWN:
        info = ctypes.cast(l_param, ctypes.POINTER(MSLLHOOKSTRUCT)).contents
        with state_lock:
            if state["armed"]:
                state["click"] = {"x": int(info.pt.x), "y": int(info.pt.y),
                                  "label": state["label"]}
                state["armed"] = False
    return user32.CallNextHookEx(None, n_code, w_param, l_param)

def hook_loop():
    module = kernel32.GetModuleHandleW(None)
    hook = user32.SetWindowsHookExW(WH_MOUSE_LL, mouse_callback, module, 0)
    if not hook:
        print("Could not start Windows mouse listener. Error:", ctypes.get_last_error())
        return
    msg = wintypes.MSG()
    while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
        user32.TranslateMessage(ctypes.byref(msg))
        user32.DispatchMessageW(ctypes.byref(msg))
    user32.UnhookWindowsHookEx(hook)

def screen_size():
    return int(user32.GetSystemMetrics(0)), int(user32.GetSystemMetrics(1))

def safe_click(x, y):
    width, height = screen_size()
    if not (0 <= x < width and 0 <= y < height):
        raise ValueError("Coordinates outside screen")
    point = POINT()
    user32.GetCursorPos(ctypes.byref(point))
    if point.x <= 1 and point.y <= 1:
        stopped.set()
        raise PermissionError("Emergency stop is active")
    stopped.clear()
    user32.SetCursorPos(x, y)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    user32.mouse_event(0x0004, 0, 0, 0, 0)

class Handler(BaseHTTPRequestHandler):
    server_version = "JoyPaintLocal/1.0"

    def log_message(self, fmt, *args):
        print("Local request:", fmt % args)

    def _headers(self, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        origin = self.headers.get("Origin", "")
        if origin == APP_ORIGIN:
            self.send_header("Access-Control-Allow-Origin", APP_ORIGIN)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            if self.headers.get("Access-Control-Request-Private-Network") == "true":
                self.send_header("Access-Control-Allow-Private-Network", "true")
        self.end_headers()

    def _allowed(self):
        origin = self.headers.get("Origin")
        host = self.headers.get("Host", "")
        return origin == APP_ORIGIN and host in (f"{HOST}:{PORT}", f"localhost:{PORT}")

    def _json(self, status=200, **data):
        payload = json.dumps(data).encode("utf-8")
        self._headers(status)
        self.wfile.write(payload)

    def do_OPTIONS(self):
        if not self._allowed():
            self._json(403, error="Origin not allowed")
            return
        self._json(204)

    def do_GET(self):
        if not self._allowed():
            self._json(403, error="Origin not allowed")
            return
        if self.path == "/status":
            width, height = screen_size()
            self._json(ok=True, screen={"width": width, "height": height})
        elif self.path == "/last":
            with state_lock:
                click = state["click"]
                state["click"] = None
            self._json(click=click)
        else:
            self._json(404, error="Not found")

    def do_POST(self):
        if not self._allowed():
            self._json(403, error="Origin not allowed")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length > 4096:
                self._json(413, error="Request too large")
                return
            data = json.loads(self.rfile.read(length) or b"{}")
            if self.path == "/arm":
                with state_lock:
                    state.update(armed=True, click=None,
                                 label=str(data.get("label", "target"))[:100])
                self._json(ok=True)
            elif self.path == "/click":
                safe_click(int(data["x"]), int(data["y"]))
                self._json(ok=True)
            elif self.path == "/stop":
                with state_lock:
                    state["armed"] = False
                stopped.set()
                self._json(ok=True)
            else:
                self._json(404, error="Not found")
        except (ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
            self._json(400, error=str(exc))
        except PermissionError as exc:
            self._json(403, error=str(exc))
        except Exception:
            self._json(500, error="Local helper error")

if __name__ == "__main__":
    if __import__("sys").platform != "win32":
        raise SystemExit("This helper is for Windows only.")
    threading.Thread(target=hook_loop, daemon=True).start()
    print("Joy of Painting helper is running at http://127.0.0.1:8765")
    print("Only the Joy of Painting website can send it commands.")
    print("Emergency stop: move your mouse to the top-left corner.")
    print("Keep this window open while painting. Press Ctrl+C to close.")
    try:
        ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        print("\nHelper stopped.")
