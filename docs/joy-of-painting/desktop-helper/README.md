# Minecraft Joy of Painting helper (Windows)

Requirements: Windows 10/11 and Python 3.10+ from https://www.python.org/downloads/ (enable **Add Python to PATH**).

1. Download this helper folder from the repository.
2. Double-click `install_and_run.bat`; first launch installs dependencies.
3. Keep the helper console open.
4. Open https://joy-of-painting-guide.onrender.com, click **Connect to helper**, and allow local network access if Chrome asks.
5. Generate the guide. Capture the top-left and bottom-right pixel centers of the Minecraft canvas.
6. Capture each palette swatch used by the image.
7. Test click and verify it lands on the top-left pixel, then press Start.

Keep Minecraft visible and in the foreground. Do not move or resize the Minecraft window, change GUI scale, or move the canvas after calibration. Use a 1-pixel brush. The helper does not read your screen or know your datapack colors; you teach it the screen coordinates by clicking them.

Safety: it binds only to 127.0.0.1. Painting begins only after Start. Pause, resume and Stop are available. Move the mouse to the extreme top-left screen corner for PyAutoGUI's emergency fail-safe. Test on a small image first; this tool physically clicks your computer.
