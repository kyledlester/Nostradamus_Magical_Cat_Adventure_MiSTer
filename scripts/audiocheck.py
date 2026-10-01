#!/usr/bin/env python3
"""Compare the FPGA sound board's output (sim/tb/tb_sound.sv -> signed 16-bit mono at 1 MHz)
with MAME's audio (mame nost -wavwrite, 48 kHz mono) over the same interval.

Reports: RMS level ratio, correlation of 10 ms RMS envelopes, and correlation of the average
magnitude spectra (0-12 kHz) - a coarse check that the same music/effects play at the same pitch,
tempo and relative loudness. Writes the FPGA audio as a 48 kHz WAV for listening.

  audiocheck.py FPGA.raw MAME.wav [--start S] [--out fpga.wav]
"""
import argparse, wave, sys
import numpy as np


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fpga")
    ap.add_argument("mame")
    ap.add_argument("--start", type=float, default=0.2, help="seconds to skip (silent boot)")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    f = np.frombuffer(open(a.fpga, "rb").read(), dtype="<i2").astype(np.float64)
    t_f = np.arange(len(f)) / 1e6
    w = wave.open(a.mame)
    m = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64)
    rate = w.getframerate()
    n = min(len(m), int(t_f[-1] * rate))
    t_m = np.arange(n) / rate
    # low-pass the 1 MHz stream (moving average ~20 samples) then sample at MAME's instants
    k = 21
    fl = np.convolve(f, np.ones(k) / k, mode="same")
    fr = np.interp(t_m, t_f, fl)
    m = m[:n]
    s0 = int(a.start * rate)
    fr, m = fr[s0:], m[s0:]
    if a.out:
        o = wave.open(a.out, "wb")
        o.setnchannels(1); o.setsampwidth(2); o.setframerate(rate)
        o.writeframes(np.clip(fr, -32768, 32767).astype("<i2").tobytes())
        o.close()
    rms_f, rms_m = np.sqrt(np.mean(fr ** 2)), np.sqrt(np.mean(m ** 2))
    win = rate // 100
    nb = len(m) // win
    ef = np.sqrt((fr[: nb * win].reshape(nb, win) ** 2).mean(axis=1))
    em = np.sqrt((m[: nb * win].reshape(nb, win) ** 2).mean(axis=1))
    env_corr = np.corrcoef(ef, em)[0, 1] if ef.std() > 0 and em.std() > 0 else 0.0
    seg = 4096
    ns = len(m) // seg
    sf = np.abs(np.fft.rfft(fr[: ns * seg].reshape(ns, seg) * np.hanning(seg), axis=1)).mean(axis=0)
    sm = np.abs(np.fft.rfft(m[: ns * seg].reshape(ns, seg) * np.hanning(seg), axis=1)).mean(axis=0)
    band = slice(1, int(12000 / (rate / seg)))
    spec_corr = np.corrcoef(np.log1p(sf[band]), np.log1p(sm[band]))[0, 1]
    print(f"interval {a.start:.2f}-{t_m[-1]:.2f} s: RMS fpga {rms_f:.0f} mame {rms_m:.0f} (ratio {rms_f / max(rms_m, 1):.2f}); "
          f"10 ms envelope correlation {env_corr:.3f}; log-spectrum correlation {spec_corr:.3f}")
    ok = env_corr > 0.8 and spec_corr > 0.9
    print("PASS AUDIOCHECK" if ok else "FAIL AUDIOCHECK")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
