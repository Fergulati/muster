#!/usr/bin/env python3
"""Cut a landing-page clip from raw screen recordings (scripts/demo/README.md).

    scripts/demo/edit.py scripts/demo/clips/split.json [--raw DIR] [--out DIR]

An edit list is JSON:

    {"name": "split", "width": 1280,
     "segments": [
        {"src": "s2-alice", "in": 0.5, "out": 17, "label": "Alice"},
        {"src": "s2-bob", "in": 14.5, "out": 19, "label": "Bob", "lapse": 6},
        {"pair": ["s2-alice", "s2-bob"], "at": 94, "hold": 3, "labels": ["Alice", "Bob"]}
     ]}

A segment plays one window from `in` to `out` seconds of its raw take, at real speed. A
wait is time-lapsed, never cut (`lapse`: N thins runs of identical frames to at most 1 in N),
so it still reads as a wait, briefly. `hold` freezes the segment's last frame for that many
seconds, for a beat worth reading. `crop` (W:H:X:Y of the raw frame) frames one part of the
window, larger; every segment of a clip must come out the same size. `speed` plays a
segment faster than real time, for an animation (the room map's Replay) rather than a wait. A `pair`
segment holds both windows side by side, frozen at `at`, for `hold` seconds: the payoff.
Writes <out>/<name>.mp4 (H.264, faststart, muted) and <out>/<name>.jpg, its poster (the
last frame).
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

FFMPEG = os.environ.get("FFMPEG", "ffmpeg")
FPS = 30


def run(args):
    r = subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", *args])
    if r.returncode != 0:
        sys.exit(f"ffmpeg failed: {' '.join(args)}")


def label_filter(text, w):
    if not text:
        return ""
    fs = max(16, w // 64)
    return (f",drawtext=text='{text}':x=w-tw-{fs}:y={fs}:fontsize={fs}:fontcolor=white"
            f":box=1:boxcolor=0x4B33C4@0.92:boxborderw={fs // 2}")


def one(raw, seg, w, out):
    src = os.path.join(raw, seg["src"] + ".mkv")
    lapse = int(seg.get("lapse", 1))
    vf = (f"mpdecimate=hi=64*6:lo=64*2:frac=0.33:max={lapse},setpts=N/{FPS}/TB," if lapse > 1 else "")
    if seg.get("speed"):  # play faster than real time (an animation the viewer need not sit through)
        vf += f"setpts=PTS/{float(seg['speed'])},"
    if seg.get("crop"):   # W:H:X:Y of the raw frame: frame one part of the window, larger
        vf += f"crop={seg['crop']},"
    vf += f"scale={w}:-2:flags=lanczos{label_filter(seg.get('label', ''), w)},fps={FPS},format=yuv420p"
    if seg.get("hold"):
        vf += f",tpad=stop_mode=clone:stop_duration={seg['hold']}"
    run(["-ss", str(seg["in"]), "-to", str(seg["out"]), "-i", src, "-vf", vf, "-an",
         "-c:v", "libx264", "-preset", "medium", "-crf", "16", out])


def pair(raw, seg, w, out):
    """Both windows at one moment, cropped to `crop` (W:H:X:Y of the raw frame, default the
    whole window), stacked top and bottom, letterboxed to the clip's own frame (w x 5w/8)."""
    a, b = [os.path.join(raw, s + ".mkv") for s in seg["pair"]]
    la, lb = (seg.get("labels") or ["", ""])[:2]
    h = w * 5 // 8
    crop = f"crop={seg['crop']}," if seg.get("crop") else ""
    half = h // 2 - 4
    fit = f"scale=-2:{half}:flags=lanczos"
    fc = (f"[0:v]{crop}{fit}{label_filter(la, w)}[a];[1:v]{crop}{fit}{label_filter(lb, w)}[b];"
          f"[a]pad=iw:ih+8:0:0:color=0x111412[ap];[ap][b]vstack,"
          f"scale='min({w},iw)':-2,pad={w}:{h}:(ow-iw)/2:(oh-ih)/2:color=0x111412,format=yuv420p,"
          f"loop=loop={int(seg.get('hold', 3) * FPS)}:size=1:start=0,fps={FPS}")
    run(["-ss", str(seg["at"]), "-i", a, "-ss", str(seg["at"]), "-i", b, "-frames:v",
         str(int(seg.get("hold", 3) * FPS)), "-filter_complex", fc, "-an",
         "-c:v", "libx264", "-preset", "medium", "-crf", "16", out])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("edit")
    ap.add_argument("--raw", default=".run/demo/raw")
    ap.add_argument("--out", default="site/media")
    o = ap.parse_args()
    spec = json.load(open(o.edit))
    w = int(spec.get("width", 1280))
    os.makedirs(o.out, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        parts = []
        for i, seg in enumerate(spec["segments"]):
            p = os.path.join(tmp, f"{i:02d}.mp4")
            (pair if "pair" in seg else one)(o.raw, seg, w, p)
            parts.append(p)
        lst = os.path.join(tmp, "list.txt")
        with open(lst, "w") as f:
            f.writelines(f"file '{p}'\n" for p in parts)
        mp4 = os.path.join(o.out, spec["name"] + ".mp4")
        # the page's copy: small, muted, starts playing before it has fully loaded
        run(["-f", "concat", "-safe", "0", "-i", lst, "-c:v", "libx264", "-preset", "slow",
             "-crf", str(spec.get("crf", 27)), "-pix_fmt", "yuv420p", "-movflags", "+faststart",
             "-an", mp4])
        run(["-sseof", "-0.2", "-i", mp4, "-frames:v", "1", "-q:v", "3",
             os.path.join(o.out, spec["name"] + ".jpg")])
    dur = subprocess.run([FFMPEG, "-hide_banner", "-i", mp4], capture_output=True, text=True).stderr
    d = next((l.split("Duration:")[1].split(",")[0].strip() for l in dur.splitlines() if "Duration:" in l), "?")
    print(f"{mp4}: {os.path.getsize(mp4) // 1024} KB, {d}")


if __name__ == "__main__":
    main()
