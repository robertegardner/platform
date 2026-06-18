#!/usr/bin/env python3
"""Plot a wxsat CU8 baseband: power-vs-time (pass hump?) + PSD at peak (LRPT
carrier?). Usage: wxsat_baseband_plot.py <baseband.cu8> <out.png> [samplerate]"""
import sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

path, out = sys.argv[1], sys.argv[2]
rate = int(sys.argv[3]) if len(sys.argv) > 3 else 1_024_000
BLK = 1 << 20

pwr, peak_off, peak_val, off = [], 0, -1.0, 0
with open(path, "rb") as f:
    while True:
        raw = np.frombuffer(f.read(BLK * 2), dtype=np.uint8)
        if raw.size < 2:
            break
        iq = (raw[0::2].astype(np.float32) - 127.5) + 1j * (raw[1::2].astype(np.float32) - 127.5)
        m = float(np.mean(np.abs(iq)))
        pwr.append(m)
        if m > peak_val:
            peak_val, peak_off = m, off
        off += raw.size
pwr = np.array(pwr)
t = np.arange(len(pwr)) * (BLK / rate)

with open(path, "rb") as f:
    f.seek(peak_off)
    raw = np.frombuffer(f.read(BLK * 2), dtype=np.uint8)
iq = (raw[0::2].astype(np.float32) - 127.5) + 1j * (raw[1::2].astype(np.float32) - 127.5)
NFFT = 4096
nseg = len(iq) // NFFT
win = np.hanning(NFFT)
psd = (np.abs(np.fft.fftshift(np.fft.fft(iq[:nseg*NFFT].reshape(nseg, NFFT) * win, axis=1), axes=1))**2).mean(0)
psd_db = 10*np.log10(psd + 1e-6)
fk = (np.arange(NFFT) - NFFT/2) * (rate/NFFT) / 1e3

fig, ax = plt.subplots(2, 1, figsize=(12, 8), dpi=110)
ax[0].plot(t, pwr, lw=0.7, color="#1f6feb")
ax[0].axhline(np.median(pwr), color="#8a99b0", ls="--", lw=0.8, label=f"median {np.median(pwr):.1f}")
ax[0].set_xlabel("time (s, AOS→LOS)"); ax[0].set_ylabel("mean |IQ|")
ax[0].set_title(f"Power vs time — a satellite pass = a hump near mid-pass "
                f"(max/median {pwr.max()/np.median(pwr):.2f})")
ax[0].grid(alpha=0.25); ax[0].legend(fontsize=8)
ax[1].plot(fk, psd_db, lw=0.5, color="#238636")
ax[1].axvspan(-72, 72, color="#ffb03a", alpha=0.12, label="LRPT band (±72 kHz)")
ax[1].set_xlabel("offset from 137.9 MHz (kHz)"); ax[1].set_ylabel("PSD (dB)")
ax[1].set_xlim(-256, 256)
ax[1].set_title("Spectrum at peak block — LRPT = a ~140 kHz hump at center")
ax[1].grid(alpha=0.25); ax[1].legend(fontsize=8)
fig.tight_layout(); fig.savefig(out)
print("wrote", out)
