#!/usr/bin/env python3
"""rf_sweep.py — wideband spectrum sweep THROUGH an rtl_tcp server (no device
release). Connects as a client, steps the center frequency across a band,
Welch-averages an FFT per step, stitches a spectrum, finds the noise floor +
peaks, and renders a PNG. Safe for a flaky-USB host: the dongle is never
opened/closed locally, only retuned over the rtl_tcp protocol.

Usage: rf_sweep.py <host> <port> <f_start_mhz> <f_stop_mhz> <out.png> [gain_tenths]
"""
import socket
import struct
import sys

import numpy as np

SET_FREQ, SET_RATE, SET_GAIN_MODE, SET_GAIN, SET_AGC = 0x01, 0x02, 0x03, 0x04, 0x08
# 1.024 Msps is the proven-safe rate on p24's marginal USB (2.4 Msps glitches it,
# rtlsdr read_reg -4). Keep the central 0.9 MHz of each 1.024 MHz capture.
RATE = 1_024_000
STEP = 900_000
NFFT = 4096
NSEG = 32                 # Welch segments per step (32*4096 = 131072 samples)
SETTLE = 65536            # samples discarded after each retune (PLL settle)
DC_NOTCH = 20_000         # exclude +/- this around each center (R820T DC spike)

# Rough VHF/UHF service map for labeling spikes (MHz ranges).
SERVICES = [
    (88, 108, "FM broadcast"), (108, 118, "aero nav/VOR"), (118, 137, "airband AM"),
    (137, 138, "wx-sat / sat downlink"), (138, 144, "mil/gov VHF"), (144, 148, "2m ham"),
    (148, 150, "mil/gov"), (150, 156, "VHF business/public-safety"),
    (156, 158, "marine VHF"), (158, 162, "VHF business"),
    (162.4, 162.56, "NOAA weather radio"), (162.56, 174, "VHF gov/business"),
    (174, 216, "VHF-hi TV / DAB"), (216, 225, "1.25m ham / maritime"),
    (225, 400, "mil air UHF"), (400, 406, "sat / met-aids"), (406, 420, "gov UHF"),
    (420, 450, "70cm ham"), (450, 470, "UHF business"), (470, 512, "UHF T-band/TV"),
]


def service(mhz):
    for lo, hi, name in SERVICES:
        if lo <= mhz < hi:
            return name
    return "—"


def cmd(s, c, p):
    s.sendall(struct.pack(">BI", c, p & 0xFFFFFFFF))


def recvall(s, n):
    buf = bytearray()
    while len(buf) < n:
        ch = s.recv(min(1 << 16, n - len(buf)))
        if not ch:
            raise IOError("rtl_tcp closed")
        buf += ch
    return bytes(buf)


def main():
    host, port = sys.argv[1], int(sys.argv[2])
    f0, f1 = float(sys.argv[3]) * 1e6, float(sys.argv[4]) * 1e6
    out = sys.argv[5]
    gain = int(sys.argv[6]) if len(sys.argv) > 6 else 300

    s = socket.create_connection((host, port), timeout=15)
    s.settimeout(20)
    hdr = recvall(s, 12)
    if hdr[:4] != b"RTL0":
        print("bad rtl_tcp magic", file=sys.stderr); return 1
    cmd(s, SET_RATE, RATE)
    cmd(s, SET_AGC, 0)
    cmd(s, SET_GAIN_MODE, 1)
    cmd(s, SET_GAIN, gain)

    win = np.hanning(NFFT).astype(np.float32)
    winpow = (win ** 2).sum()
    centers = np.arange(f0 + RATE / 2, f1, STEP)
    all_f, all_p = [], []
    for i, fc in enumerate(centers):
        cmd(s, SET_FREQ, int(fc))
        recvall(s, SETTLE * 2)                       # drain settling samples
        raw = np.frombuffer(recvall(s, NSEG * NFFT * 2), dtype=np.uint8).astype(np.float32)
        iq = (raw[0::2] - 127.5) + 1j * (raw[1::2] - 127.5)
        seg = iq.reshape(NSEG, NFFT) * win
        psd = (np.abs(np.fft.fftshift(np.fft.fft(seg, axis=1), axes=1)) ** 2).mean(0)
        psd /= (winpow * RATE)
        pdb = 10 * np.log10(psd + 1e-9)
        f = fc + (np.arange(NFFT) - NFFT / 2) * (RATE / NFFT)
        keep = (np.abs(f - fc) <= STEP / 2) & (np.abs(f - fc) >= DC_NOTCH)
        all_f.append(f[keep]); all_p.append(pdb[keep])
        if i % 25 == 0:
            print(f"  swept {fc/1e6:.0f} MHz ({i+1}/{len(centers)})", file=sys.stderr)
    s.close()

    f = np.concatenate(all_f); p = np.concatenate(all_p)
    order = np.argsort(f); f, p = f[order], p[order]
    fm = f / 1e6

    # Noise floor: sliding low-percentile (robust to spikes).
    n = len(p); w = max(201, n // 200 | 1)
    floor = np.empty(n)
    for k in range(0, n, w // 2):
        a, b = max(0, k - w // 2), min(n, k + w // 2)
        floor[k:min(k + w // 2, n)] = np.percentile(p[a:b], 25)
    floor = np.convolve(floor, np.ones(w) / w, mode="same")
    med = float(np.median(p))

    # Peaks: >= floor+8 dB, cluster within 30 kHz, keep the strongest per cluster.
    thr = floor + 8.0
    cand = np.where(p > thr)[0]
    peaks = []
    if len(cand):
        groups = np.split(cand, np.where(np.diff(f[cand]) > 30_000)[0] + 1)
        for g in groups:
            j = g[np.argmax(p[g])]
            peaks.append((fm[j], p[j], p[j] - floor[j]))
    peaks.sort(key=lambda x: x[2], reverse=True)

    print(f"\nNoise floor (relative dB): median {med:.1f}, "
          f"range {np.percentile(p,10):.1f}..{np.percentile(p,90):.1f}")
    print(f"Found {len(peaks)} spike clusters >= floor+8 dB. Top 20:")
    print(f"  {'freq MHz':>10}  {'dB>floor':>8}  service")
    for mhz, _, dbf in peaks[:20]:
        print(f"  {mhz:10.3f}  {dbf:8.1f}  {service(mhz)}")

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(15, 6), dpi=110)
    ax.plot(fm, p, lw=0.4, color="#1f6feb")
    ax.plot(fm, floor, lw=1.0, color="#d29922", label="noise floor (25th pct)")
    for mhz, pw, dbf in peaks[:18]:
        ax.annotate(f"{mhz:.2f}\n{service(mhz)}", (mhz, pw),
                    fontsize=6.5, ha="center", va="bottom", color="#b62324",
                    xytext=(0, 3), textcoords="offset points")
        ax.plot(mhz, pw, ".", color="#b62324", ms=4)
    ax.set_xlabel("Frequency (MHz)"); ax.set_ylabel("Relative power (dB)")
    ax.set_title(f"p24 Nooelec / 137 MHz V-dipole — RF sweep {sys.argv[3]}-{sys.argv[4]} MHz "
                 f"(gain {gain/10:.0f} dB, uncalibrated)")
    ax.grid(alpha=0.25); ax.legend(loc="upper right", fontsize=8)
    ax.margins(x=0.005)
    fig.tight_layout(); fig.savefig(out)
    print(f"\nwrote {out}")


if __name__ == "__main__":
    sys.exit(main())
