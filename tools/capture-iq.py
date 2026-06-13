#!/usr/bin/env python3
"""Phase 0B transport proof: pull IQ from a SoapyRemote source and measure it.

Opens driver=remote against the Pi's dx-R2 source server, tunes, streams CS16
for a fixed duration, and reports achieved sample rate, wire format, and
overflow/error counts. Optionally dumps the first N seconds to a raw file for an
FM-demod sanity check. Measures throughput without writing the whole stream to
disk (8 Msps CS16 ~= 32 MB/s).
"""
import argparse
import sys
import time

import numpy as np
import SoapySDR
from SoapySDR import (SOAPY_SDR_RX, SOAPY_SDR_CS16, SOAPY_SDR_OVERFLOW,
                      SOAPY_SDR_TIMEOUT)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--remote", default="radio.srvr:55001")
    ap.add_argument("--remote-driver", default="sdrplay",
                    help="device the remote server should open (remote:driver=...)")
    ap.add_argument("--freq", type=float, default=98.0e6)
    ap.add_argument("--rate", type=float, default=8.0e6)
    ap.add_argument("--antenna", default="Antenna A")
    ap.add_argument("--gain", type=float, default=None)
    ap.add_argument("--duration", type=float, default=20.0)
    ap.add_argument("--dump", default=None, help="raw CS16 output file (optional)")
    ap.add_argument("--dump-secs", type=float, default=2.0)
    ap.add_argument("--prot", default=None,
                    help="SoapyRemote stream protocol passed to setupStream "
                         "(tcp = lossless/retransmit, udp = default firehose, udt = reliable-UDP)")
    args = ap.parse_args()

    dev_args = f"driver=remote,remote={args.remote}"
    if args.remote_driver:
        dev_args += f",remote:driver={args.remote_driver}"
    print(f"[*] opening {dev_args}", flush=True)
    dev = SoapySDR.Device(dev_args)

    print(f"[*] antennas: {dev.listAntennas(SOAPY_SDR_RX, 0)}", flush=True)
    rates = dev.getSampleRateRange(SOAPY_SDR_RX, 0)
    print(f"[*] sample-rate ranges: {[(r.minimum(), r.maximum()) for r in rates]}", flush=True)

    dev.setSampleRate(SOAPY_SDR_RX, 0, args.rate)
    dev.setFrequency(SOAPY_SDR_RX, 0, args.freq)
    if args.antenna:
        try:
            dev.setAntenna(SOAPY_SDR_RX, 0, args.antenna)
        except Exception as e:
            print(f"[!] setAntenna({args.antenna!r}) failed: {e}", flush=True)
    if args.gain is not None:
        dev.setGain(SOAPY_SDR_RX, 0, args.gain)

    achieved_rate = dev.getSampleRate(SOAPY_SDR_RX, 0)
    print(f"[*] requested rate {args.rate/1e6:.3f} Msps -> device reports "
          f"{achieved_rate/1e6:.3f} Msps", flush=True)
    print(f"[*] freq {dev.getFrequency(SOAPY_SDR_RX, 0)/1e6:.3f} MHz, "
          f"antenna {dev.getAntenna(SOAPY_SDR_RX, 0)!r}", flush=True)

    stream_args = {"remote:prot": args.prot} if args.prot else {}
    print(f"[*] setupStream args: {stream_args or '(default: udp)'}", flush=True)
    st = dev.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0], stream_args)
    dev.activateStream(st)

    chunk = 1 << 16  # 65536 complex samples per read
    buff = np.empty(2 * chunk, np.int16)  # CS16 interleaved I,Q

    dump_fh = open(args.dump, "wb") if args.dump else None
    dump_budget = int(args.dump_secs * achieved_rate) if dump_fh else 0

    total = 0
    overflows = 0   # readStream returned SOAPY_SDR_OVERFLOW (-4): samples dropped
    timeouts = 0    # readStream returned SOAPY_SDR_TIMEOUT (-1): no data — a stall
    other_errs = {}
    t0 = time.monotonic()
    t_end = t0 + args.duration
    last_report = t0
    try:
        while time.monotonic() < t_end:
            sr = dev.readStream(st, [buff], chunk, timeoutUs=2_000_000)
            ret = sr.ret
            if ret > 0:
                total += ret
                if dump_fh and dump_budget > 0:
                    n = min(ret, dump_budget)
                    dump_fh.write(buff[: 2 * n].tobytes())
                    dump_budget -= n
            elif ret == SOAPY_SDR_OVERFLOW:
                overflows += 1
            elif ret == SOAPY_SDR_TIMEOUT:
                timeouts += 1
            else:
                other_errs[ret] = other_errs.get(ret, 0) + 1
            now = time.monotonic()
            if now - last_report >= 2.0:
                el = now - t0
                print(f"    t={el:5.1f}s  samples={total:>12d}  "
                      f"rate={total/el/1e6:6.3f} Msps  overflow={overflows}  "
                      f"timeout={timeouts}  err={other_errs}", flush=True)
                last_report = now
    finally:
        dev.deactivateStream(st)
        dev.closeStream(st)
        if dump_fh:
            dump_fh.close()

    el = time.monotonic() - t0
    eff = total / el if el else 0
    print("\n=== RESULT ===", flush=True)
    print(f"  duration         : {el:.1f} s", flush=True)
    print(f"  wire format      : CS16 (4 bytes/sample)", flush=True)
    print(f"  requested rate   : {args.rate/1e6:.3f} Msps", flush=True)
    print(f"  device rate      : {achieved_rate/1e6:.3f} Msps", flush=True)
    print(f"  effective rate   : {eff/1e6:.3f} Msps "
          f"({eff*4/1e6*8:.0f} Mbps over the wire)", flush=True)
    print(f"  samples captured : {total}", flush=True)
    print(f"  overflows (-4)   : {overflows}", flush=True)
    print(f"  timeouts (-1)    : {timeouts}", flush=True)
    print(f"  other errors     : {other_errs}", flush=True)
    if args.dump:
        print(f"  dump file        : {args.dump} "
              f"(first ~{args.dump_secs}s CS16 @ {achieved_rate/1e6:.3f} Msps)", flush=True)

    healthy = (overflows == 0 and timeouts == 0 and not other_errs
               and eff >= 0.95 * achieved_rate)
    print(f"  VERDICT          : {'CLEAN' if healthy else 'DEGRADED'}", flush=True)
    sys.exit(0 if healthy else 2)


if __name__ == "__main__":
    main()
