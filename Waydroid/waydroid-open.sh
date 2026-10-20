#!/usr/bin/env bash
# Start Waydroid (container + session + full UI) at 480x854.
set -u

WIDTH=480
HEIGHT=854
DPI=240   # 480px wide @ 240dpi = 360dp, phone-like. Lower (160-200) = smaller UI.

# 1. Container
if ! systemctl is-active --quiet waydroid-container; then
    echo "Starting waydroid-container..."
    sudo systemctl start waydroid-container || { echo "Container failed to start"; exit 1; }
fi

# 2. Resolution props (only take effect on a fresh session)
if ! waydroid status 2>/dev/null | grep -q "Session:.*RUNNING"; then
    waydroid prop set persist.waydroid.width "$WIDTH"
    waydroid prop set persist.waydroid.height "$HEIGHT"

    echo "Starting session..."
    nohup waydroid session start >/tmp/waydroid-session.log 2>&1 &

    # Wait up to 30s for the session
    for _ in $(seq 1 30); do
        waydroid status 2>/dev/null | grep -q "Session:.*RUNNING" && break
        sleep 1
    done
fi

# 3. DPI
sudo waydroid shell wm density "$DPI" >/dev/null 2>&1

# 4. UI
waydroid show-full-ui
