#!/usr/bin/env python3
"""fm-duck: server-side talk-ducking relay.

Pulls the local Icecast /fm.mp3, decodes to PCM, classifies music vs talk
(same heuristic as the radio web UI / Android app duck, v2 tuning), applies a
near-mute gain ramp during talk/commercial stretches, re-encodes, and sources
the result back to the local Icecast as /fm-duck.mp3 — so dumb network
streamers (WiiM etc.) get ducking by URL choice alone, while /fm.mp3 stays
untouched for everyone else.

Lifecycle: when the upstream mount drops (the Pi restarts the stream on every
tune), the decoder hits EOF and we exit non-zero; systemd restarts us until
the mount returns. The duck mount therefore tracks /fm.mp3's availability,
same as any direct listener.

Config via environment (systemd EnvironmentFile=/etc/fm-duck.env, root-only —
it carries the Icecast source password inside MOUNT_URL).
"""

import os
import subprocess
import sys
import time

import numpy as np

SR = 44100
HOP = 2048                      # samples per analysis/gain block (~46 ms, ~21.5 fps)

# --- classifier tuning (v2 — keep in sync with radio.html + Android) --------
FRAMES = 160                    # ~7.4 s long window (duck decision)
SHORT_FRAMES = 60               # ~2.8 s short window (recovery decision)
MIN_FRAMES = 80                 # ~3.7 s before the first verdict
EVAL_EVERY = 8                  # re-score ~2.7x/s
W_BEAT, W_HF, W_STEADY = 0.50, 0.30, 0.20
# HF/CV scales are SERVER-calibrated against linear-PCM rfft magnitudes —
# the client constants (8-bit / dB-mapped FFTs) do not transfer. Probe data
# 2026-06-12 on live FM music: beat~0.52, hf_ratio~0.22, cv~0.39; speech is
# expected well below/above respectively. (/tmp/duck_probe.py on this LXC.)
HF_FULL, CV_FULL = 0.20, 1.20
MUSIC_TH, TALK_TH = 0.55, 0.35  # talk low: quiet sparse verses must not duck
MUSIC_HOLD_MS, TALK_HOLD_MS = 1500, 8000
DUCK_VOL = 0.07
DUCK_RAMP_S, UNDUCK_RAMP_S = 1.2, 0.25

BIN_HZ = SR / HOP
BASS = slice(max(1, round(43 / BIN_HZ)), round(200 / BIN_HZ) + 1)
MID = slice(round(300 / BIN_HZ), round(3400 / BIN_HZ) + 1)
HIGH = slice(round(4000 / BIN_HZ), round(10800 / BIN_HZ) + 1)


class Classifier:
    """Long window decides ducking; short recent window decides recovery (so
    music-resume isn't dragged down by stale talk frames in the history)."""

    def __init__(self):
        self.bass, self.mid, self.high = [], [], []
        self.state = "music"
        self.score = 0.0
        self.parts = (0.0, 0.0, 0.0)  # (beat, hf_ratio, cv) of the last long eval
        self.frames = 0
        self.music_run = 0.0
        self.talk_run = 0.0
        self.last_eval = 0.0

    def _score_window(self, start):
        b = np.asarray(self.bass[start:])
        m = np.asarray(self.mid[start:])
        h = np.asarray(self.high[start:])
        n = len(b)

        # Beat: normalized autocorrelation peak of the bass envelope,
        # 0.25-0.8 s lags (frame period ~46 ms -> lags 5..17).
        x = b - b.mean()
        r0 = float((x * x).sum()) + 1e-9
        beat = 0.0
        for lag in range(5, min(18, n - 8)):
            beat = max(beat, float((x[:-lag] * x[lag:]).sum()) / r0)
        beat = min(1.0, max(0.0, beat))

        # Sustained high-frequency content.
        tot = b + m + h
        hf_ratio = float(np.mean(np.divide(h, tot, out=np.zeros_like(h), where=tot > 1e-9)))
        hf_score = min(1.0, hf_ratio / HF_FULL)

        # Speech-band envelope steadiness (speech is bursty at syllable rate).
        mean_mid = float(m.mean())
        cv = float(m.std() / mean_mid) if mean_mid > 1e-9 else 1.0
        steady = min(1.0, max(0.0, 1.0 - cv / CV_FULL))

        if start == 0:  # keep long-window components for the heartbeat log
            self.parts = (beat, hf_ratio, cv)
        return min(1.0, max(0.0, W_BEAT * beat + W_HF * hf_score + W_STEADY * steady))

    def add(self, mags):
        """Feed one frame of rfft magnitudes; returns True on a state change."""
        self.bass.append(float(mags[BASS].sum()))
        self.mid.append(float(mags[MID].sum()))
        self.high.append(float(mags[HIGH].sum()))
        if len(self.bass) > FRAMES:
            self.bass.pop(0)
            self.mid.pop(0)
            self.high.pop(0)

        self.frames += 1
        if self.frames % EVAL_EVERY or len(self.bass) < MIN_FRAMES:
            return False

        self.score = self._score_window(0)
        short = (
            self._score_window(max(0, len(self.bass) - SHORT_FRAMES))
            if self.state == "talk"
            else self.score
        )

        now = time.monotonic() * 1000
        dt = min(2000.0, now - self.last_eval) if self.last_eval else 0.0
        self.last_eval = now
        self.music_run = self.music_run + dt if short >= MUSIC_TH else 0.0
        self.talk_run = self.talk_run + dt if self.score <= TALK_TH else 0.0

        prev = self.state
        if self.state == "talk" and self.music_run >= MUSIC_HOLD_MS:
            self.state = "music"
        if self.state == "music" and self.talk_run >= TALK_HOLD_MS:
            self.state = "talk"
        return self.state != prev


def main():
    source_url = os.environ["SOURCE_URL"]
    mount_url = os.environ["MOUNT_URL"]

    dec = subprocess.Popen(
        ["ffmpeg", "-hide_banner", "-loglevel", "error",
         "-i", source_url, "-f", "f32le", "-ac", "1", "-ar", str(SR), "pipe:1"],
        stdout=subprocess.PIPE,
    )
    enc = subprocess.Popen(
        ["ffmpeg", "-hide_banner", "-loglevel", "error",
         "-f", "f32le", "-ac", "1", "-ar", str(SR), "-i", "pipe:0",
         "-c:a", "libmp3lame", "-b:a", "128k",
         "-content_type", "audio/mpeg", "-ice_name", "FM (talk-ducked)",
         "-f", "mp3", mount_url],
        stdin=subprocess.PIPE,
    )

    cls = Classifier()
    window = np.hanning(HOP).astype(np.float32)
    gain = 1.0
    last_beat = time.monotonic()
    print("fm-duck: relaying %s -> /fm-duck.mp3" % source_url, flush=True)

    try:
        while True:
            buf = dec.stdout.read(HOP * 4)
            if len(buf) < HOP * 4:
                print("fm-duck: source ended (tune/restart upstream?) — exiting for restart", flush=True)
                break

            x = np.frombuffer(buf, dtype=np.float32)
            if cls.add(np.abs(np.fft.rfft(x * window))):
                print("fm-duck: %s (score %.2f)" % (cls.state, cls.score), flush=True)

            target = DUCK_VOL if cls.state == "talk" else 1.0
            if gain != target:
                ramp = DUCK_RAMP_S if target < gain else UNDUCK_RAMP_S
                step = (1.0 - DUCK_VOL) * (HOP / SR) / ramp
                end = gain + max(-step, min(step, target - gain))
                enc.stdin.write((x * np.linspace(gain, end, HOP, dtype=np.float32)).tobytes())
                gain = end
            else:
                enc.stdin.write((x * gain).tobytes() if gain != 1.0 else buf)

            now = time.monotonic()
            if now - last_beat > 60:
                last_beat = now
                print(
                    "fm-duck: alive — %s, score %.2f (beat %.2f hf %.3f cv %.2f), gain %.2f"
                    % (cls.state, cls.score, *cls.parts, gain),
                    flush=True,
                )
    except BrokenPipeError:
        print("fm-duck: encoder/icecast pipe broke — exiting for restart", flush=True)
    finally:
        for p in (dec, enc):
            try:
                p.kill()
            except OSError:
                pass
    sys.exit(1)  # systemd Restart=always brings us back when the mount returns


if __name__ == "__main__":
    main()
