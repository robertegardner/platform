#!/usr/bin/env python3
"""Post-mortem a wxsat CU8 baseband: is there a satellite pass (power hump) and
an LRPT carrier (spectral hump near center), or just noise?

Usage: wxsat_baseband_check.py <baseband.cu8> [samplerate]
"""
import sys
import numpy as np

path = sys.argv[1]
rate = int(sys.argv[2]) if len(sys.argv) > 2 else 1_024_000
BLK = 1 << 20  # 1M complex samples per block

# --- power vs time (pass hump?) ---
pwr, peak_off, peak_val = [], 0, -1
off = 0
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
secs = BLK / rate
t = np.arange(len(pwr)) * secs
med = float(np.median(pwr))
print(f"file: {path}  ({off//2/1e6:.0f} Msamples, {off//2/rate:.0f}s @ {rate} Sps)")
print(f"power |IQ|: median {med:.2f}, max {pwr.max():.2f} (at t={t[pwr.argmax()]:.0f}s), "
      f"min {pwr.min():.2f}, max/median {pwr.max()/max(med,1e-3):.2f}")
# A real pass = a smooth hump: power rises then falls. Print a coarse sparkline.
bars = " .:-=+*#%@"
lo, hi = pwr.min(), pwr.max()
spark = "".join(bars[min(8, int((v - lo) / max(hi - lo, 1e-6) * 8))] for v in pwr[::max(1, len(pwr)//70)])
print(f"power-vs-time: [{spark}]  (left=AOS .. right=LOS)")

# --- PSD at the peak-power block (LRPT carrier ~120-150 kHz wide at center?) ---
with open(path, "rb") as f:
    f.seek(peak_off)
    raw = np.frombuffer(f.read(BLK * 2), dtype=np.uint8)
iq = (raw[0::2].astype(np.float32) - 127.5) + 1j * (raw[1::2].astype(np.float32) - 127.5)
NFFT = 4096
nseg = len(iq) // NFFT
win = np.hanning(NFFT)
psd = (np.abs(np.fft.fftshift(np.fft.fft(iq[:nseg*NFFT].reshape(nseg, NFFT) * win, axis=1), axes=1))**2).mean(0)
psd_db = 10*np.log10(psd + 1e-6)
fk = (np.arange(NFFT) - NFFT/2) * (rate/NFFT) / 1e3  # kHz
floor = np.percentile(psd_db, 30)
# in-band = central +/-80 kHz (LRPT lives here); compare to the floor
inband = psd_db[np.abs(fk) <= 80]
print(f"PSD @ peak block: floor {floor:.1f} dB, in-band(+/-80kHz) peak {inband.max():.1f} dB "
      f"(+{inband.max()-floor:.1f} over floor), in-band mean {inband.mean():.1f} (+{inband.mean()-floor:.1f})")
# spectral sparkline across +/-256 kHz
sel = np.abs(fk) <= 256
ps = psd_db[sel]; lo2, hi2 = ps.min(), ps.max()
ss = "".join(bars[min(8,int((v-lo2)/max(hi2-lo2,1e-6)*8))] for v in ps[::max(1,len(ps)//70)])
print(f"spectrum +/-256kHz: [{ss}]  (center = LRPT carrier if present)")
