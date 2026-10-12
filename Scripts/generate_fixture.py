#!/usr/bin/env python3
"""Generates the synthetic health fixture. Nothing here comes from real Health data.

Usage: python3 Scripts/generate_fixture.py
"""
import json
import math
import random
import uuid
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "Packages/LongGameKit/Sources/HealthIngest/Fixtures/health-fixture.json"
DAYS = 100
HR_INTERVAL = 60  # seconds between heart-rate points

rng = random.Random(20270110)


def new_id():
    return str(uuid.UUID(int=rng.getrandbits(128), version=4)).upper()


def hr_series(minutes, base, peak=None, intervals=False):
    """Warm up, hold near `base` (or alternate with `peak`), cool down."""
    series = []
    for m in range(max(1, int(minutes))):
        frac = m / max(1, minutes - 1)
        if frac < 0.1:
            bpm = 95 + (base - 95) * (frac / 0.1)
        elif frac > 0.93:
            bpm = base - 15 * ((frac - 0.93) / 0.07)
        elif intervals and peak and (m // 4) % 2 == 1:
            bpm = peak
        else:
            bpm = base + 6 * math.sin(m / 7) + frac * 5
        series.append(round(bpm + rng.uniform(-3, 3)))
    return series


def workout(day, minute, sport, name, minutes, *, source="Apple Watch", km=None, base=140, peak=None,
            intervals=False, hr=True, power=None, cadence=None, session=None):
    w = {
        "id": new_id(),
        "sourceName": source,
        "sport": sport,
        "activityName": name,
        "dayOffset": day,
        "startMinute": minute,
        "durationSeconds": minutes * 60,
        "activeEnergyKcal": round(minutes * (base - 60) * 0.11),
    }
    if km is not None:
        w["distanceMeters"] = round(km * 1000)
    if hr:
        w["heartRate"] = hr_series(minutes, base, peak, intervals)
        w["effortScore"] = round(min(10, max(1, (base - 100) / 9 + minutes / 60)), 1)
    if power is not None:
        w["averagePowerWatts"] = power
    if cadence is not None:
        w["averageCadence"] = cadence
    if session is not None:
        w["sessionID"] = session
    return w


workouts = []
for day in range(-DAYS + 1, 1):
    week = (day + DAYS - 1) // 7
    weekday = (day + DAYS - 1) % 7  # 0 = first day of a fixture week
    build = 1 + 0.03 * week  # gentle progression
    recovery_week = week % 4 == 3
    scale = build * (0.7 if recovery_week else 1.0)
    skip = rng.random() < 0.08  # the occasional missed session

    if weekday == 0 and not skip:
        workouts.append(workout(day, 6 * 60 + 15, "swim", "Pool Swim", round(40 * scale), km=round(1.8 * scale, 2), base=128))
    elif weekday == 1 and not skip:
        workouts.append(workout(day, 6 * 60 + 30, "run", "Outdoor Run", round(45 * scale), km=round(7.5 * scale, 2),
                                base=150, peak=172, intervals=True, cadence=172))
        workouts.append(workout(day, 18 * 60, "strength", "Traditional Strength Training", 35, base=112))
    elif weekday == 2 and not skip:
        workouts.append(workout(day, 17 * 60 + 30, "bike", "Indoor Cycle", round(60 * scale), km=round(30 * scale, 1),
                                base=138, power=round(165 * build), cadence=88))
    elif weekday == 3 and not skip:
        workouts.append(workout(day, 6 * 60 + 30, "run", "Outdoor Run", round(40 * scale), km=round(6.5 * scale, 2),
                                base=140, cadence=168))
    elif weekday == 4 and not skip:
        workouts.append(workout(day, 12 * 60, "strength", "Core Training", 25, base=105))
    elif weekday == 5:
        # Long ride recorded twice: Apple Watch (HR only) and Wahoo (power, summary HR).
        minutes = round(120 * scale)
        workouts.append(workout(day, 8 * 60, "bike", "Outdoor Cycle", minutes, km=round(55 * scale, 1), base=135))
        workouts.append(workout(day, 8 * 60 + 1, "bike", "Cycling", minutes - 2, source="Wahoo", km=round(55.3 * scale, 1),
                                base=135, hr=week % 2 == 0, power=round(158 * build), cadence=85))
    elif weekday == 6 and not skip:
        workouts.append(workout(day, 7 * 60 + 30, "run", "Outdoor Run", round(75 * scale), km=round(12 * scale, 2),
                                base=145, cadence=166))

# One brick recorded as a single multisport workout, split into legs.
brick = new_id()
workouts.append(workout(-24, 9 * 60, "bike", "Outdoor Cycle", 70, km=32, base=140, power=170, cadence=86, session=brick))
workouts.append(workout(-24, 10 * 60 + 13, "run", "Outdoor Run", 22, km=4, base=156, cadence=170, session=brick))

# "Other" activities: extra fatigue the coach should see.
workouts.append(workout(-16, 10 * 60, "other", "Hiking", 190, km=13.5, base=118))
workouts.append(workout(-9, 19 * 60, "other", "Curling", 110, base=96))
workouts.append(workout(-3, 12 * 60 + 30, "other", "Walking", 45, km=4.1, base=102))
# A third-party app that wrote only a summary (no heart-rate samples).
workouts.append(workout(-12, 18 * 60, "other", "Yoga", 50, source="Studio App", hr=False))

workouts.sort(key=lambda w: (w["dayOffset"], w["startMinute"]))

days = []
for day in range(-DAYS + 1, 1):
    trained_hard = any(w["dayOffset"] == day - 1 and w["durationSeconds"] > 5400 for w in workouts)
    sleep = rng.gauss(7.3, 0.6) * 3600
    if rng.random() < 0.07:
        sleep -= 5400  # a short night
    entry = {
        "dayOffset": day,
        "restingHR": round(rng.gauss(52, 1.8) + (3 if trained_hard else 0)),
        "hrvSDNN": round(rng.gauss(62, 7) - (9 if trained_hard else 0), 1),
        "sleepSeconds": round(sleep),
        "sleepCoreSeconds": round(sleep * 0.55),
        "sleepDeepSeconds": round(sleep * 0.17),
        "sleepREMSeconds": round(sleep * 0.22),
        "sleepAwakeSeconds": round(sleep * 0.06),
        "respiratoryRate": round(rng.gauss(14.2, 0.5), 1),
        "steps": round(max(1500, rng.gauss(8500, 2600))),
        "activeEnergyKcal": round(max(150, rng.gauss(620, 190))),
        "bodyMassKg": round(74.5 - 0.01 * (day + DAYS) + rng.uniform(-0.4, 0.4), 1),
    }
    if (day + DAYS) % 9 == 0:
        entry["vo2Max"] = round(47 + 0.02 * (day + DAYS) + rng.uniform(-0.3, 0.3), 1)
    days.append(entry)

fixture = {
    "heartRateIntervalSeconds": HR_INTERVAL,
    "profile": {"ageYears": 38, "biologicalSex": "male", "heightCm": 180},
    "workouts": workouts,
    "days": days,
}

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(fixture, separators=(",", ":")))
print(f"{len(workouts)} workouts, {len(days)} days -> {OUT} ({OUT.stat().st_size // 1024} KB)")
