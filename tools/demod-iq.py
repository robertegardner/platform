#!/usr/bin/env python3
"""Offline WBFM demod of a raw CS16 IQ dump — the backpressure-free twin of the
live rx_fm chain.

Reads interleaved int16 I/Q (as written by capture-iq.py --dump), runs the same
WBFM path rx_fm does (quadrature discriminator → anti-alias lowpass → decimate to
250 kHz MPX), and writes s16le mono MPX to stdout. Pipe that to `redsea -r 250000`
for an RDS check and to ffmpeg for an audio/level check — all consuming the file at
full speed, so NO downstream pipe can backpressure the capture (unlike the live
tee→redsea→ffmpeg chain). If RDS decodes here but not live, the fault is live-pipe
backpressure, not the SoapyRemote IQ delivery.

numpy-only (no scipy) so it runs on the radio-compute LXC as-is.
"""
import argparse
import sys

import numpy as np


def lowpass_taps(num_taps: int, cutoff: float, fs: float) -> np.ndarray:
    n = np.arange(num_taps) - (num_taps - 1) / 2
    h = np.sinc(2 * cutoff / fs * n) * np.hamming(num_taps)
    return (h / h.sum()).astype(np.float32)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("infile", nargs="?", default="-",
                    help="CS16 IQ file ('-' = stdin)")
    ap.add_argument("--rate", type=float, default=2.0e6, help="input IQ sample rate")
    ap.add_argument("--decim", type=int, default=8, help="decimation to MPX rate")
    ap.add_argument("--cutoff", type=float, default=120_000.0,
                    help="anti-alias cutoff before decimation (keeps 57k RDS)")
    args = ap.parse_args()

    out_rate = args.rate / args.decim
    sys.stderr.write(f"demod-iq: in {args.rate/1e6:.3f} Msps -> MPX {out_rate/1e3:.0f} kHz "
                     f"(decim {args.decim}, cutoff {args.cutoff/1e3:.0f} kHz)\n")
    sys.stderr.flush()

    fh = sys.stdin.buffer if args.infile == "-" else open(args.infile, "rb")
    taps = lowpass_taps(127, args.cutoff, args.rate)

    block_complex = 1 << 20            # 1Mi complex samples per block
    prev = np.complex64(0)             # discriminator continuity across blocks
    fir_hist = np.zeros(len(taps) - 1, dtype=np.float32)  # FIR continuity
    phase_carry = 0                    # keep decimation phase aligned across blocks
    stdout = sys.stdout.buffer
    total_in = 0
    total_out = 0

    while True:
        raw = np.frombuffer(fh.read(block_complex * 2 * 2), dtype=np.int16)
        if raw.size < 2:
            break
        n = raw.size // 2
        iq = (raw[0:2 * n:2].astype(np.float32) + 1j * raw[1:2 * n:2].astype(np.float32))
        iq = (iq / np.float32(32768.0)).astype(np.complex64)
        total_in += n

        # Quadrature FM discriminator: angle of x[k]*conj(x[k-1]).
        x = np.concatenate(([prev], iq))
        disc = np.angle(x[1:] * np.conj(x[:-1])).astype(np.float32)
        prev = iq[-1]

        # Anti-alias lowpass (carry history so block edges don't click).
        ext = np.concatenate((fir_hist, disc))
        filt = np.convolve(ext, taps, mode="valid").astype(np.float32)
        fir_hist = disc[-(len(taps) - 1):].copy()

        # Decimate with a running phase so we never drop/dup a sample at edges.
        idx = np.arange(phase_carry, len(filt), args.decim)
        mpx = filt[idx]
        phase_carry = (phase_carry - len(filt)) % args.decim

        # ±pi maps to full scale; WBFM deviation keeps us well clear of clip.
        pcm = np.clip(mpx * np.float32(32767.0 / np.pi), -32767, 32767).astype(np.int16)
        stdout.write(pcm.tobytes())
        total_out += pcm.size

    stdout.flush()
    sys.stderr.write(f"demod-iq: {total_in} IQ samples -> {total_out} MPX samples "
                     f"({total_out/out_rate:.1f}s)\n")
    sys.stderr.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
