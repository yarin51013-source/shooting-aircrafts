from flask import Flask, request, jsonify
from flask_cors import CORS
import pyautogui
from pynput import mouse
from threading import Lock

app = Flask(__name__)
CORS(app, resources={r"/*": {"origins": ["https://joy-of-painting-guide.onrender.com"]}})
pyautogui.FAILSAFE = True
pyautogui.PAUSE = 0.015
state = {"armed": False, "click": None, "label": ""}
lock = Lock()

def on_click(x, y, button, pressed):
    if pressed:
        with lock:
            if state["armed"]:
                state["click"] = {"x": int(x), "y": int(y), "label": state["label"]}
                state["armed"] = False
    return True

listener = mouse.Listener(on_click=on_click)
listener.daemon = True
listener.start()

@app.get("/status")
def status():
    w, h = pyautogui.size()
    return jsonify(ok=True, screen={"width": w, "height": h})

@app.post("/arm")
def arm():
    data = request.get_json(silent=True) or {}
    with lock:
        state.update(armed=True, click=None, label=str(data.get("label", "target"))[:100])
    return jsonify(ok=True)

@app.get("/last")
def last():
    with lock:
        click = state["click"]
        state["click"] = None
    return jsonify(click=click)

@app.post("/click")
def click():
    data = request.get_json(force=True)
    x, y = int(data["x"]), int(data["y"])
    w, h = pyautogui.size()
    if not (0 <= x < w and 0 <= y < h):
        return jsonify(error="Coordinates outside screen"), 400
    pyautogui.click(x, y)
    return jsonify(ok=True)

@app.post("/stop")
def stop():
    with lock:
        state["armed"] = False
    return jsonify(ok=True)

if __name__ == "__main__":
    print("Joy of Painting helper listening at http://127.0.0.1:8765")
    print("Keep this window open. Move the mouse to the top-left screen corner for emergency stop.")
    app.run(host="127.0.0.1", port=8765, debug=False, threaded=True)
