#!/usr/bin/env python3
"""Finds out which system activity causes audio stalls.

While the Fire TV streams to the app (with per-second stats on:
`defaults write local.bluetooth-audio-bridge perSecondStats -bool YES`), this runs each trigger
several times in random order, with quiet gaps in between, and checks whether the received rate drops
afterwards. It also records the system log (activity level changes, BLE scan parameters, Wi-Fi scans)
for the whole run, so stalls nobody triggered can be matched to what the system did at that moment.

Don't touch the Mac while it runs (input changes the activity level, which is one of the suspects).

    probe/stall-test.py [--rounds 3] [--only ble,wifi] [--out DIR]
"""
import argparse, datetime as dt, os, random, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, "Probe.app")
APPLOG = os.path.expanduser("~/Library/Logs/Bluetooth Audio Bridge.log")
NORMAL_KBPS = 200          # a second below this counts as degraded (normal is ~225-237)
WINDOW = 25                # seconds after a trigger's start that are attributed to it
GAP = 40                   # seconds from one trigger's start to the next

def probe(mode, secs):
    def run():
        out = os.path.join(args.out, "probe.log")
        subprocess.run(["perl", "-e", "alarm %d; exec @ARGV" % (secs + 30), "open", "-W", "--stdout", out,
                        "--stderr", out, PROBE, "--args", "--trigger", mode, str(secs)])
    return run

def cpu(secs):
    def run():
        n = os.cpu_count() or 8
        ps = [subprocess.Popen(["perl", "-e", "$t=time+%d; while(time<$t){}" % secs]) for _ in range(n)]
        for p in ps: p.wait()
    return run

def net(secs):
    def run():
        subprocess.run(["curl", "-s", "-o", "/dev/null", "--max-time", str(secs),
                        "https://speed.cloudflare.com/__down?bytes=500000000"])
    return run

def disk(secs):
    def run():
        f = os.path.join(args.out, "disk.tmp")
        subprocess.run(["perl", "-e", "alarm %d; exec @ARGV" % secs, "dd", "if=/dev/zero", "of=" + f,
                        "bs=1m", "count=4000"], stderr=subprocess.DEVNULL)
        try: os.remove(f)
        except OSError: pass
    return run

def audio(secs):
    def run():   # a second audio stream on the Mac, very quiet (like YouTube playing alongside)
        end = time.time() + secs
        while time.time() < end:
            subprocess.run(["afplay", "-v", "0.03", "/System/Library/Sounds/Submarine.aiff"])
    return run

def nothing(secs):
    return lambda: time.sleep(0)

TRIGGERS = {
    "none":         nothing(0),       # control
    "useractivity": probe("useractivity", 1),
    "ble":          probe("ble", 10),
    "ble-nodup":    probe("ble-nodup", 10),
    "inquiry":      probe("inquiry", 8),
    "wifi":         probe("wifi", 10),
    "awdl":         probe("awdl", 10),
    "cpu":          cpu(10),
    "net":          net(10),
    "disk":         disk(8),
    "audio":        audio(8),
}

LOG_PREDICATE = (
    '(eventMessage CONTAINS "Activity level changed") OR '
    '(process == "bluetoothd" AND eventMessage CONTAINS "Returning scan parameters") OR '
    '(process == "bluetoothd" AND eventMessage CONTAINS "inquiry") OR '
    '(process == "sharingd" AND eventMessage CONTAINS "Starting scan") OR '
    '(process == "airportd" AND eventMessage CONTAINS "SCAN request received")'
)

def ts(s):
    return dt.datetime.strptime(s[:23], "%Y-%m-%d %H:%M:%S.%f").timestamp()

def read_rates(t0):
    """Per-second received rate from the app log since t0: [(time, kbps, underruns)]."""
    out = []
    rx = re.compile(r"^(\S+ \S+) \[\d+\] s1: (\d+) kbit/s, buffer \d+ ms, underruns (\d+)")
    with open(APPLOG, errors="replace") as f:
        for line in f:
            m = rx.match(line)
            if m:
                t = ts(m.group(1))
                if t >= t0: out.append((t, int(m.group(2)), int(m.group(3))))
    return out

def read_syslog(path):
    ev = []
    rx = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\S*\s+\S+\s+(\S+?)\[")
    with open(path, errors="replace") as f:
        for line in f:
            m = rx.match(line)
            if not m: continue
            msg = line[m.end():]
            if "Activity level changed" in msg:
                if m.group(2) != "sharingd": continue
                k = "level " + re.search(r"changed (.*)", msg).group(1).strip()
            elif "Returning scan parameters" in msg:
                main_ = re.search(r"Main:(\S+)", msg)
                dc = re.search(r"QoS:\(use=\d+ dc=(\d+%)", msg)
                k = "LE scan %s%s" % (main_.group(1) if main_ else "?", " (" + dc.group(1) + ")" if dc else "")
            elif "Starting scan" in msg:
                k = "sharingd scan " + ("High" if "rate High" in msg or "ScanRate High" in msg else "normal")
            elif "SCAN request received" in msg:
                who = re.search(r"from pid \d+ \(([^)]*)\)", msg)
                k = "Wi-Fi scan by " + (who.group(1) if who else "?")
            else:
                k = "BT inquiry"
            ev.append((ts(m.group(1)), k))
    return ev

def degraded(rates, a, b):
    sec = [r for r in rates if a <= r[0] < b]
    bad = [r for r in sec if r[1] < NORMAL_KBPS]
    und = (sec[-1][2] - sec[0][2]) if sec else 0
    return len(sec), len(bad), min((r[1] for r in sec), default=0), und

def wait_quiet(seconds=15, timeout=120):
    end, warned = time.time() + timeout, False
    while time.time() < end:
        r = read_rates(time.time() - seconds)
        if len(r) >= seconds - 2 and all(x[1] >= NORMAL_KBPS for x in r): return True
        if not r and not warned:
            print("  no s1 stats in the app log: is the Fire TV streaming and perSecondStats on?", flush=True)
            warned = True
        time.sleep(2)
    return False

def current_level(logpath):
    lv = None
    for _, k in read_syslog(logpath):
        if k.startswith("level "): lv = k.split("-> ")[-1]
    return lv

def main():
    global args
    ap = argparse.ArgumentParser()
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--only", default="")
    ap.add_argument("--out", default=os.path.join(HERE, "stall-test-" + time.strftime("%Y%m%d-%H%M%S")))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    names = [n for n in TRIGGERS if not args.only or n in args.only.split(",") or n == "none"]
    plan = names * args.rounds
    random.shuffle(plan)
    syslog = os.path.join(args.out, "syslog.txt")
    ls = subprocess.Popen(["/usr/bin/log", "stream", "--style", "compact", "--predicate", LOG_PREDICATE],
                          stdout=open(syslog, "w"), stderr=subprocess.DEVNULL)
    start = time.time()
    runs = []
    print("%d triggers, about %d min. Don't touch the Mac." % (len(plan), len(plan) * (GAP + 10) // 60), flush=True)
    try:
        for i, name in enumerate(plan, 1):
            if not wait_quiet():
                print("  stream not clean for 2 min, continuing anyway", flush=True)
            if name == "useractivity":
                # only meaningful from the idle level; wait (up to 3 min) for macOS to drop to Screen
                end = time.time() + 180
                while current_level(syslog) not in (None, "7 (Screen)") and time.time() < end: time.sleep(3)
            lv = current_level(syslog)
            t0 = time.time()
            TRIGGERS[name]()
            runs.append((name, t0, lv))
            print("[%2d/%d] %s %-12s (level before: %s)" % (i, len(plan), time.strftime("%H:%M:%S"), name, lv), flush=True)
            time.sleep(max(0, t0 + GAP - time.time()))
        time.sleep(5)
    finally:
        ls.terminate()
    report(runs, start, syslog)

def report(runs, start, syslog):
    rates = read_rates(start - 5)
    ev = read_syslog(syslog)
    lines = []
    p = lambda s="": (lines.append(s), print(s))
    p("\n== Per trigger (window: %d s after start; degraded = seconds below %d kbit/s) ==" % (WINDOW, NORMAL_KBPS))
    summary = {}
    for name, t0, lv in runs:
        n, bad, mn, und = degraded(rates, t0, t0 + WINDOW)
        lvch = [k for t, k in ev if t0 - 1 <= t < t0 + WINDOW and k.startswith("level ")]
        summary.setdefault(name, []).append((bad, mn, und, lvch))
        p("%s %-12s degraded %2ds  min %3d kbit/s  underruns +%d  %s" % (
            time.strftime("%H:%M:%S", time.localtime(t0)), name, bad, mn, und, ("level: " + "; ".join(lvch)) if lvch else ""))
    p("\n== Summary ==")
    for name, rs in sorted(summary.items()):
        hit = sum(1 for r in rs if r[0] >= 3)
        p("%-12s %d/%d runs with a stall (>=3 s degraded), avg %.1f s degraded" % (
            name, hit, len(rs), sum(r[0] for r in rs) / len(rs)))
    # stalls nobody triggered on purpose: list what the system log shows just before
    p("\n== All stalls in the run, with system events 15 s before to 5 s after the start ==")
    t, prev_bad = None, False
    stalls = []
    for r in rates:
        bad = r[1] < NORMAL_KBPS
        if bad and not prev_bad: t = r[0]
        if not bad and prev_bad and t is not None: stalls.append((t, r[0]))
        prev_bad = bad
    for a, b in stalls:
        if b - a < 2: continue
        trig = [n for n, t0, _ in runs if t0 - 2 <= a < t0 + WINDOW]
        near = ["%+.1fs %s" % (t - a, k) for t, k in ev if a - 15 <= t <= a + 5]
        p("%s  %2.0f s  trigger: %-12s events: %s" % (time.strftime("%H:%M:%S", time.localtime(a)), b - a,
                                                     ",".join(trig) or "-", "; ".join(near) or "-"))
    with open(os.path.join(args.out, "report.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\nReport: " + os.path.join(args.out, "report.txt"))

if __name__ == "__main__":
    main()
