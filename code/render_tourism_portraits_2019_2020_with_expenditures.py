#!/usr/bin/env python3
"""
Offline fixed-media renderer for the tourism sound portraits.

This script mirrors the SuperCollider mapping:
- Tourist arrivals: aircraft sample, 1 event = 10 million arrivals
- Tourism receipts: money sample, 1 event = 10 billion receipts
- Tourism expenditures: continuous coin-drop loop, dramatic amplitude curve
- Tourism departures: cabin beep sample, 1 event = 5 million departures

Countries without receipts in the selected years are removed from the
comparison. If expenditure is missing, the coin loop stays silent.
"""

from __future__ import annotations

import csv
import hashlib
import math
import wave
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
CSV_PATH = ROOT / "data/world_tourism_economy_data.csv"
OUTPUT_DIR = ROOT / "output"

ARRIVAL_SAMPLE = ROOT / "sample_assets/ucak kalkis.wav"
MONEY_SAMPLE_WAV = ROOT / "sample_assets/money.wav"
COIN_LOOP_SAMPLE = ROOT / "sample_assets/coin drop loop yeni.wav"
DEPARTURE_SAMPLE = ROOT / "sample_assets/kabin beep.wav"

COUNTRIES = [
    ("France", "France"),
    ("United States", "United States"),
    ("Mexico", "Mexico"),
    ("Italy", "Italy"),
    ("Poland", "Poland"),
    ("Hungary", "Hungary"),
    ("Croatia", "Croatia"),
    ("Turkey", "Turkiye"),
    ("Thailand", "Thailand"),
    ("Germany", "Germany"),
]

YEARS = [2019, 2020]
SR = 44100
COUNTRY_DUR = 24.0
GAP_DUR = 2.0
FADE_DUR = 2.5

TOURISTS_PER_ARRIVAL_SOUND = 10_000_000
TOURISTS_PER_DEPARTURE_BEEP = 5_000_000
RECEIPTS_PER_MONEY_SOUND = 10_000_000_000
EXPENDITURE_UNITS_FOR_FULL_COIN_LOOP = 5.0


def parse_number(value: str | None) -> float | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text or text.lower() in {"na", "n/a", "nan", "null", "none"}:
        return None
    return float(text)


def safe_name(text: str) -> str:
    return (
        text.lower()
        .replace(" ", "_")
        .replace("/", "_")
        .replace(",", "")
        .replace("(", "")
        .replace(")", "")
    )


def convert_money_sample() -> Path:
    return MONEY_SAMPLE_WAV


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        channels = w.getnchannels()
        sample_rate = w.getframerate()
        sample_width = w.getsampwidth()
        frames = w.readframes(w.getnframes())

    if sample_width != 2:
        raise ValueError(f"Only 16-bit PCM WAV is supported: {path}")

    data = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    data = data.reshape(-1, channels)
    if channels == 1:
        data = np.repeat(data, 2, axis=1)
    elif channels > 2:
        data = data[:, :2]

    if sample_rate != SR:
        data = resample(data, sample_rate / SR)
    return data


def resample(audio: np.ndarray, rate: float) -> np.ndarray:
    if audio.size == 0:
        return audio
    old_len = audio.shape[0]
    new_len = max(1, int(old_len / rate))
    old_x = np.arange(old_len)
    new_x = np.linspace(0, old_len - 1, new_len)
    left = np.interp(new_x, old_x, audio[:, 0])
    right = np.interp(new_x, old_x, audio[:, 1])
    return np.column_stack([left, right]).astype(np.float32)


def pan_stereo(audio: np.ndarray, pan: float) -> np.ndarray:
    pan = float(np.clip(pan, -1.0, 1.0))
    left_gain = math.sqrt((1.0 - pan) * 0.5)
    right_gain = math.sqrt((1.0 + pan) * 0.5)
    out = audio.copy()
    mono = audio.mean(axis=1)
    out[:, 0] = mono * left_gain
    out[:, 1] = mono * right_gain
    return out


def add_sample(target: np.ndarray, sample: np.ndarray, start_sec: float, amp: float, pan: float = 0.0, rate: float = 1.0) -> None:
    if amp <= 0:
        return
    rendered = resample(sample, rate) if abs(rate - 1.0) > 0.001 else sample
    rendered = pan_stereo(rendered, pan) * amp
    start = int(start_sec * SR)
    if start >= target.shape[0]:
        return
    end = min(target.shape[0], start + rendered.shape[0])
    length = end - start
    if length > 0:
        target[start:end, :] += rendered[:length, :]


def add_loop(target: np.ndarray, loop: np.ndarray, amp: float, pan: float = 0.0, rate: float = 1.0) -> None:
    if amp <= 0:
        return
    rendered_loop = resample(loop, rate) if abs(rate - 1.0) > 0.001 else loop
    repeats = int(math.ceil(target.shape[0] / rendered_loop.shape[0])) + 1
    tiled = np.tile(rendered_loop, (repeats, 1))[: target.shape[0], :]
    target += pan_stereo(tiled, pan) * amp


def fade_envelope(n: int) -> np.ndarray:
    env = np.ones(n, dtype=np.float32)
    fade_n = int(FADE_DUR * SR)
    if fade_n > 0:
        fade = np.sin(np.linspace(0, math.pi / 2, fade_n, dtype=np.float32)) ** 2
        env[:fade_n] *= fade
        env[-fade_n:] *= fade[::-1]
    return env[:, None]


def write_wav(path: Path, audio: np.ndarray) -> None:
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    if peak > 0.98:
        audio = audio * (0.98 / peak)
    pcm = np.clip(audio, -1.0, 1.0)
    pcm = (pcm * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def linlin(value: float, in_min: float, in_max: float, out_min: float, out_max: float) -> float:
    if in_max == in_min:
        return (out_min + out_max) * 0.5
    return out_min + (value - in_min) * (out_max - out_min) / (in_max - in_min)


def normalize_log(values: list[float | None]) -> list[float]:
    scaled = [math.log10(max(v, 0.0) + 1.0) if v is not None else None for v in values]
    valid = [v for v in scaled if v is not None]
    if not valid:
        return [0.0 for _ in values]
    lo, hi = min(valid), max(valid)
    out = []
    for value in scaled:
        if value is None:
            out.append(0.0)
        elif hi == lo:
            out.append(0.5)
        else:
            out.append(float(np.clip((value - lo) / (hi - lo), 0.0, 1.0)))
    return out


def load_portraits() -> list[dict]:
    rows = list(csv.DictReader(CSV_PATH.open(newline="", encoding="utf-8-sig")))
    by_key = {}
    for row in rows:
        country = row.get("country", "").strip()
        year = parse_number(row.get("year"))
        if country and year is not None:
            by_key[(country, int(year))] = row

    portraits = []
    for display_country, csv_country in COUNTRIES:
        for year in YEARS:
            row = by_key.get((csv_country, year))
            if row is None:
                continue
            data = {
                "country": display_country,
                "csv_country": csv_country,
                "year": year,
                "arrivals": parse_number(row.get("tourism_arrivals")),
                "receipts": parse_number(row.get("tourism_receipts")),
                "expenditures": parse_number(row.get("tourism_expenditures")),
                "departures": parse_number(row.get("tourism_departures")),
            }
            if data["receipts"] is None:
                continue
            missing = []
            if data["arrivals"] is None:
                missing.append("tourist arrivals")
            if data["expenditures"] is None:
                missing.append("tourism expenditures")
            if data["departures"] is None:
                missing.append("tourism departures")
            data["missing"] = missing
            portraits.append(data)

    for key in ["arrivals", "receipts", "expenditures", "departures"]:
        norms = normalize_log([p[key] for p in portraits])
        for portrait, norm in zip(portraits, norms):
            portrait[key + "_norm"] = norm
    return portraits


def event_count(value: float | None, scale: float) -> int:
    if value is None:
        return 0
    return max(0, int(math.floor((value / scale) + 0.5)))


def render_portrait(portrait: dict, samples: dict[str, np.ndarray]) -> np.ndarray:
    rng_seed = int.from_bytes(hashlib.sha256(f"{portrait['country']}:{portrait['year']}".encode()).digest()[:4], "big")
    rng = np.random.default_rng(rng_seed)
    n = int(COUNTRY_DUR * SR)
    audio = np.zeros((n, 2), dtype=np.float32)

    arrivals = portrait["arrivals"] or 0.0
    receipts = portrait["receipts"] or 0.0
    expenditures = portrait["expenditures"] or 0.0
    departures = portrait["departures"] or 0.0

    arrival_count = event_count(arrivals, TOURISTS_PER_ARRIVAL_SOUND)
    money_count = event_count(receipts, RECEIPTS_PER_MONEY_SOUND)
    departure_count = event_count(departures, TOURISTS_PER_DEPARTURE_BEEP)
    coin_amount = float(np.clip(expenditures / EXPENDITURE_UNITS_FOR_FULL_COIN_LOOP, 0.0, 1.0))
    coin_curve = coin_amount ** 3.0

    arrival_amp = linlin(portrait["arrivals_norm"], 0, 1, 0.08, 0.22)
    money_amp = linlin(portrait["receipts_norm"], 0, 1, 0.05, 0.18)
    departure_amp = linlin(portrait["departures_norm"], 0, 1, 0.055, 0.16)
    coin_amp = linlin(coin_curve, 0, 1, 0.004, 0.34)

    if coin_amount > 0:
        add_loop(
            audio,
            samples["coin"],
            amp=coin_amp,
            pan=linlin(coin_curve, 0, 1, -0.18, 0.18),
            rate=linlin(coin_amount, 0, 1, 0.92, 1.08),
        )

    if arrival_count > 0:
        times = np.linspace(0.6, COUNTRY_DUR - 1.8, arrival_count)
        for t in times:
            add_sample(
                audio,
                samples["arrival"],
                start_sec=float(t),
                amp=float(rng.uniform(arrival_amp * 0.65, arrival_amp)),
                pan=float(rng.uniform(-0.35, 0.35)),
                rate=float(rng.uniform(0.92, 1.08)),
            )

    if money_count > 0:
        times = np.linspace(0.8, COUNTRY_DUR - 1.4, money_count)
        money = samples["money"]
        max_start = int(money.shape[0] * 0.55)
        for t in times:
            start = int(rng.integers(0, max_start + 1)) if max_start > 0 else 0
            add_sample(
                audio,
                money[start:, :],
                start_sec=float(t),
                amp=float(rng.uniform(money_amp * 0.55, money_amp)),
                pan=float(rng.uniform(-0.65, 0.65)),
                rate=float(rng.uniform(0.95, 1.12)),
            )

    if departure_count > 0:
        times = np.linspace(0.7, COUNTRY_DUR - 1.0, departure_count)
        pans = [-0.75, 0.75, -0.25, 0.25]
        for i, t in enumerate(times):
            add_sample(
                audio,
                samples["departure"],
                start_sec=float(t),
                amp=float(rng.uniform(departure_amp * 0.65, departure_amp)),
                pan=pans[i % len(pans)],
                rate=float(rng.uniform(0.98, 1.04)),
            )

    audio *= fade_envelope(n)
    return audio


def report_line(index: int, portrait: dict, path: Path) -> str:
    arrivals = event_count(portrait["arrivals"], TOURISTS_PER_ARRIVAL_SOUND)
    money = event_count(portrait["receipts"], RECEIPTS_PER_MONEY_SOUND)
    departures = event_count(portrait["departures"], TOURISTS_PER_DEPARTURE_BEEP)
    expenditures = portrait["expenditures"] or 0.0
    coin_amount = float(np.clip(expenditures / EXPENDITURE_UNITS_FOR_FULL_COIN_LOOP, 0.0, 1.0))
    coin_curve = coin_amount ** 3.0
    coin_amp = linlin(coin_curve, 0, 1, 0.004, 0.34) if coin_amount > 0 else 0.0
    missing = ", ".join(portrait["missing"]) if portrait["missing"] else "none"
    return (
        f"{index:02d}. {portrait['country']} {portrait['year']} -> {path.name}\n"
        f"    aircraft events: {arrivals}, money events: {money}, "
        f"departure beeps: {departures}, coin loop amount: {coin_amount:.3f}, "
        f"coin amp: {coin_amp:.3f}\n"
        f"    missing layers: {missing}\n"
    )


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    money_wav = convert_money_sample()
    samples = {
        "arrival": read_wav(ARRIVAL_SAMPLE),
        "money": read_wav(money_wav),
        "coin": read_wav(COIN_LOOP_SAMPLE),
        "departure": read_wav(DEPARTURE_SAMPLE),
    }

    portraits = load_portraits()
    rendered = {}
    report = [
        "Tourism portraits rendered with exact 2019 and 2020 rows.\n",
        "Missing cells are not invented; missing sound layers are silent.\n\n",
        f"Receipt events use decoded money sample: {money_wav.name}\n\n",
        "Expenditure coin loop uses cubic amplitude curve: (expenditure / 5.0) ** 3.\n\n",
    ]

    for idx, portrait in enumerate(portraits, 1):
        audio = render_portrait(portrait, samples)
        file_name = f"{idx:02d}_{safe_name(portrait['country'])}_{portrait['year']}.wav"
        out_path = OUTPUT_DIR / file_name
        write_wav(out_path, audio)
        rendered[(portrait["country"], portrait["year"])] = audio
        report.append(report_line(idx, portrait, out_path))

    gap = np.zeros((int(GAP_DUR * SR), 2), dtype=np.float32)
    for year in YEARS:
        year_audio = []
        for country, _csv_country in COUNTRIES:
            audio = rendered.get((country, year))
            if audio is not None:
                year_audio.append(audio)
                year_audio.append(gap)
        combined = np.vstack(year_audio)
        write_wav(OUTPUT_DIR / f"tourism_portraits_combined_{year}.wav", combined)

    all_audio = []
    for portrait in portraits:
        all_audio.append(rendered[(portrait["country"], portrait["year"])])
        all_audio.append(gap)
    write_wav(OUTPUT_DIR / "tourism_portraits_combined_2019_2020.wav", np.vstack(all_audio))

    report_path = OUTPUT_DIR / "render_report_2019_2020.txt"
    report_path.write_text("".join(report), encoding="utf-8")
    print(f"Rendered {len(portraits)} individual files into {OUTPUT_DIR}")
    print(f"Report: {report_path}")


if __name__ == "__main__":
    main()
