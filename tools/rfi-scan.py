#!/usr/bin/env python3
"""Scan a band for RFI spurs on a SoapySDR device.

Built to characterize the HF+ YouLoop's local-noise problem (its floor rose
~8 dB after dark, 2026-06-18): sweeps the band at fine resolution, estimates the
noise floor from between-channel bins, finds narrowband peaks that are NOT on the
AM 10 kHz broadcast grid (= spurs, not stations), and looks for a regular comb
spacing (the switching-supply / SMPS fundamental). Works on any device; defaults
to the remote HF+ (:55002). No effect on the dx-R2/FM path.

  rfi-scan.py                       # HF+ YouLoop, 100-1850 kHz
  rfi-scan.py --device-args 'driver=remote,remote=radio.srvr:55001,remote:driver=sdrplay' --antenna 'Antenna B'
"""
import argparse
import sys
import time
from collections import Counter

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_RX, SOAPY_SDR_CF32


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device-args",
                    default="driver=remote,remote=radio.srvr:55002,remote:driver=airspyhf")
    ap.add_argument("--antenna", default="RX")
    ap.add_argument("--gain", type=float, default=30)
    ap.add_argument("--rate", type=float, default=912000)
    ap.add_argument("--start", type=float, default=100e3, help="band start Hz")
    ap.add_argument("--stop", type=float, default=1850e3, help="band stop Hz")
    ap.add_argument("--fft", type=int, default=16384)
    ap.add_argument("--dwell", type=float, default=3.0, help="seconds averaged per hop")
    ap.add_argument("--threshold", type=float, default=10.0, help="dB above floor to flag a peak")
    ap.add_argument("--grid-guard", type=float, default=1500.0,
                    help="Hz around each 10 kHz grid point treated as broadcast")
    args = ap.parse_args()

    dev = SoapySDR.Device(SoapySDR.KwargsFromString(args.device_args))
    dev.setSampleRate(SOAPY_SDR_RX, 0, args.rate)
    try:
        dev.setAntenna(SOAPY_SDR_RX, 0, args.antenna)
    except Exception as e:
        print(f"setAntenna({args.antenna!r}): {e}", file=sys.stderr)
    try:
        dev.setGainMode(SOAPY_SDR_RX, 0, False)
    except Exception:
        pass
    dev.setGain(SOAPY_SDR_RX, 0, args.gain)
    remote = "remote" in args.device_args
    st = dev.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CF32, [0],
                         {"remote:prot": "tcp"} if remote else {})
    dev.activateStream(st)

    binhz = args.rate / args.fft
    half = args.rate / 2 * 0.9
    win = np.hanning(args.fft).astype(np.float32)
    wp = float((win * win).sum())

    hops = []
    c = args.start + half
    while c - half <= args.stop:
        hops.append(c)
        c += 2 * half

    F_all, P_all = [], []
    for hc in hops:
        dev.setFrequency(SOAPY_SDR_RX, 0, hc)
        buf = np.zeros(args.fft, np.complex64)
        t0 = time.time()
        while time.time() - t0 < 0.3:                 # settle / drain
            dev.readStream(st, [buf], args.fft, timeoutUs=300000)
        acc = np.zeros(args.fft)
        n = 0
        fill = 0
        target = int(args.dwell * args.rate / args.fft)
        t0 = time.time()
        # SoapyRemote returns ~1006-sample partial reads; fill a full FFT block.
        while n < target and time.time() - t0 < args.dwell * 3:
            r = dev.readStream(st, [buf[fill:]], args.fft - fill, timeoutUs=500000)
            if r.ret > 0:
                fill += r.ret
                if fill >= args.fft:
                    sp = np.fft.fftshift(np.fft.fft(buf * win))
                    acc += (np.abs(sp) ** 2) / wp
                    n += 1
                    fill = 0
        if n == 0:
            print(f"hop {hc/1e3:.0f} kHz: no samples", file=sys.stderr)
            continue
        psd = 10 * np.log10(acc / n + 1e-20)
        f = np.fft.fftshift(np.fft.fftfreq(args.fft, 1.0 / args.rate)) + hc
        m = (f >= args.start) & (f <= args.stop) & (np.abs(f - hc) < half)
        F_all.append(f[m])
        P_all.append(psd[m])

    dev.deactivateStream(st)
    dev.closeStream(st)
    if not F_all:
        print("no data")
        return 1

    F = np.concatenate(F_all)
    P = np.concatenate(P_all)
    order = np.argsort(F)
    F, P = F[order], P[order]

    # Noise floor: median of bins NOT within grid-guard of a 10 kHz broadcast
    # channel (those carriers would bias it). Spurs are sparse → don't move it.
    exclude = np.zeros(len(F), bool)
    for g in range(540000, 1710000, 10000):
        exclude |= np.abs(F - g) <= args.grid_guard
    floor = float(np.median(P[~exclude])) if (~exclude).any() else float(np.median(P))

    def near_grid(fhz):
        g = round(fhz / 10000) * 10000
        return abs(fhz - g) <= args.grid_guard and 530000 <= g <= 1700000

    # Peaks = contiguous runs above floor+threshold; take each run's max bin.
    above = P > floor + args.threshold
    peaks = []
    j, Nn = 0, len(P)
    while j < Nn:
        if above[j]:
            k = j
            while k < Nn and above[k]:
                k += 1
            idx = j + int(np.argmax(P[j:k]))
            peaks.append((float(F[idx]), float(P[idx])))
            j = k
        else:
            j += 1

    spurs = sorted((p for p in peaks if not near_grid(p[0])), key=lambda x: -x[1])
    bc = [p for p in peaks if near_grid(p[0])]

    print(f"device   : {args.device_args}  ant={args.antenna} gain={args.gain}")
    print(f"band     : {args.start/1e3:.0f}-{args.stop/1e3:.0f} kHz, {len(hops)} hops, "
          f"bin {binhz:.0f} Hz, dwell {args.dwell:.0f}s")
    print(f"NOISE FLOOR ~{floor:.1f} dB   broadcast carriers: {len(bc)}   off-grid spurs: {len(spurs)}")
    print("top off-grid spurs (kHz : dB above floor):")
    for f, p in spurs[:30]:
        print(f"  {f/1e3:9.2f} : +{p-floor:5.1f}")

    sf = sorted(f for f, _ in spurs)
    if len(sf) >= 3:
        diffs = np.diff(sf) / 1000.0
        common = Counter(round(d) for d in diffs if d > 0.5).most_common(8)
        print("spur spacings (kHz : count) — a dominant value = SMPS comb fundamental:")
        for val, cnt in common:
            print(f"  ~{val:>4} kHz : {cnt}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
