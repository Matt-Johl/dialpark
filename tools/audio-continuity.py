#!/usr/bin/env python3
"""Lab (lab/audio-continuity): one call's audio timeline, phone and server
side by side.

Joins the app's continuity events (the `engine: audio continuity call=…`
summary and `engine: audio event +T KIND a= b=` lines a device uploads to
data/diag/<device>/) with the server's relay accounting for the same call
(the 2 s `relay` lines and the `call ended` summary in the server log, and
the per-packet trace when the server ran with -rtp-trace), and prints a
single timeline so a drop a person heard at "about 12 s" can be read
against what removed audio on the phone and what arrived from the server
at that moment.

    tools/audio-continuity.py --app data/diag/dev_X/<upload>.log \\
        --server data/logs/dev-server.log [--trace-dir <dir>] [--call <id>]

Without --call the most recent call in the app log is used. The app's call
id is baresip's (the engine's `call=` value); the server's is the SIP
Call-ID header of the app leg, which differs. They are matched by time: the
app's "call … established" line against the server's "bridged" line
nearest to it (within 10 s). Times are printed as seconds from the app's
call start (its dial/incoming event, which is what the events count from).

Standard library only.
"""
import argparse
import re
import sys
from datetime import datetime, timezone, timedelta

ISO = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?)(Z|[+-]\d{2}:\d{2})")


def parse_ts(s):
    m = ISO.match(s)
    if not m:
        return None
    t, z = m.group(1), m.group(2)
    if z == "Z":
        z = "+00:00"
    if "." in t:
        base, frac = t.split(".")
        frac = (frac + "000000")[:6]
        t = base + "." + frac
        fmt = "%Y-%m-%dT%H:%M:%S.%f"
    else:
        fmt = "%Y-%m-%dT%H:%M:%S"
    dt = datetime.strptime(t, fmt)
    off = timedelta(hours=int(z[1:3]), minutes=int(z[4:6]))
    if z[0] == "-":
        off = -off
    return dt.replace(tzinfo=timezone(off)).astimezone(timezone.utc)


def kv(line):
    return dict(re.findall(r'(\w+)=("[^"]*"|\S+)', line))


# ---- app side ---------------------------------------------------------------

def app_calls(path):
    """Every call in an app log: dial/incoming time, established, closed,
    the continuity summary and its events."""
    calls = []
    cur = None
    for raw in open(path, errors="replace"):
        line = raw.rstrip("\n")
        ts = parse_ts(line)
        if ts is None:
            continue
        body = line.split(" ", 1)[1] if " " in line else ""
        m = re.search(r"engine: (?:dial|incoming call) .*?call[= ]?([A-Za-z0-9@._-]+)", body)
        if m or "engine: dialling" in body or "engine: incoming" in body:
            cur = {"start": ts, "id": m.group(1) if m else "?", "events": [], "windows": [], "summary": None,
                   "established": None, "closed": None, "marks": []}
            calls.append(cur)
            continue
        if cur is None:
            continue
        if "established with" in body:
            cur["established"] = ts
            m2 = re.search(r"call (\S+) established", body)
            if m2:
                cur["id"] = m2.group(1)
        elif "engine: audio session active" in body or "callkit: audio session activated" in body:
            cur["marks"].append((ts, body.split("engine: ")[-1][:60]))
        elif "engine: audio event +" in body:
            m2 = re.search(r"audio event \+([\d.]+)s (\S+) a=(-?\d+) b=(-?\d+)", body)
            if m2:
                cur["events"].append((float(m2.group(1)), m2.group(2), int(m2.group(3)), int(m2.group(4))))
        elif "engine: audio continuity call=" in body:
            cur["summary"] = body.split(": ", 2)[-1]
        elif re.search(r"engine: .* — \d+s: play=", body):
            cur["windows"].append((ts, body.split("engine: ", 1)[1]))
        elif "closed (" in body and "engine: call" in body:
            cur["closed"] = ts
    return calls


# ---- server side ------------------------------------------------------------

def server_calls(path):
    """Bridged calls in the server log with their relay lines."""
    calls = {}
    order = []
    for raw in open(path, errors="replace"):
        if "msg=" not in raw:
            continue
        d = kv(raw)
        ts = parse_ts(d.get("time", ""))
        if ts is None:
            continue
        msg = d.get("msg", "")
        cid = d.get("call")
        if not cid:
            continue
        if msg == "bridged" or msg == '"bridged"' or msg.startswith('"bridged'):
            calls[cid] = {"id": cid, "bridged": ts, "relay": [], "ended": None, "ended_line": None,
                          "from": d.get("from", "?"), "to": d.get("to", "?")}
            order.append(cid)
        elif cid in calls:
            if msg == "relay":
                calls[cid]["relay"].append((ts, d))
            elif msg in ('"call ended"',):
                calls[cid]["ended"] = ts
                calls[cid]["ended_line"] = raw.strip()
    return [calls[c] for c in order]


def match_server(app, servers):
    """The app's call id is baresip's, which is the SIP Call-ID of the app
    leg — the same string the server logs as call= — so an exact id match
    comes first. Failing that (older builds, a transfer leg), the bridged
    line nearest the app's established line, within 60 s: the two clocks
    are not synchronised (a phone ran 17 s ahead of the Mac on 2026-10-29)."""
    for s in servers:
        if s["id"] == app["id"]:
            return s
    if app["established"] is None:
        return None
    best, bd = None, timedelta(seconds=60)
    for s in servers:
        d = abs(s["bridged"] - app["established"])
        if d < bd:
            best, bd = s, d
    return best


# ---- trace --------------------------------------------------------------------

def trace_bursts(path, gap_us=5000, run_min=3):
    """Runs of packets read within gap_us of each other in a trace file."""
    rows = []
    for line in open(path):
        if line.startswith("t_us") or not line.strip():
            continue
        f = line.split("\t")
        rows.append((int(f[0]), int(f[1])))
    bursts = []
    i = 0
    while i < len(rows):
        j = i
        while j + 1 < len(rows) and rows[j + 1][0] - rows[j][0] <= gap_us:
            j += 1
        if j - i + 1 >= run_min:
            bursts.append((rows[i][0] / 1e6, j - i + 1, rows[i][1], rows[j][1]))
        i = j + 1
    gaps = []
    for a, b in zip(rows, rows[1:]):
        if b[0] - a[0] > 60000:
            gaps.append((a[0] / 1e6, (b[0] - a[0]) / 1000))
    return bursts, gaps


# ---- main --------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", required=True, help="device upload (app log)")
    ap.add_argument("--server", required=True, help="server log")
    ap.add_argument("--trace-dir", help="directory the server wrote -rtp-trace files to")
    ap.add_argument("--call", help="app call id (default: the most recent call with a continuity summary)")
    args = ap.parse_args()

    apps = app_calls(args.app)
    if not apps:
        sys.exit("no calls in the app log")
    if args.call:
        cands = [c for c in apps if c["id"] == args.call]
    else:
        cands = [c for c in apps if c["summary"]] or apps
    if not cands:
        sys.exit(f"call {args.call} not in the app log")
    app = cands[-1]
    servers = server_calls(args.server)
    srv = match_server(app, servers)
    t0 = app["start"]
    # The phone's and the server's clocks are not the same clock: server
    # times are shifted so that "bridged" lands on the app's "established"
    # (the 200 OK that bridges the call is what establishes it, ~tens of ms
    # apart), and everything is printed from the app's call start.
    shift = timedelta(0)
    if srv and app["established"]:
        shift = app["established"] - srv["bridged"]

    def rel(ts):
        return (ts - t0).total_seconds()

    def srel(ts):
        return (ts + shift - t0).total_seconds()

    print(f"call {app['id']}  app start {t0.isoformat()}  established +{rel(app['established']):.2f}s"
          if app["established"] else f"call {app['id']}  app start {t0.isoformat()}  (never established)")
    if srv:
        print(f"server call {srv['id']}  {srv['from']}→{srv['to']}  bridged +{srel(srv['bridged']):.2f}s"
              + (f"  ended +{srel(srv['ended']):.2f}s" if srv["ended"] else "")
              + f"  (server clock shifted {shift.total_seconds():+.1f}s onto the phone's)")
    else:
        print("server call: none bridged within 10 s of the app's established line")
    print()
    print("app summary:", app["summary"] or "(no continuity summary — call still open or old build)")
    if srv and srv["ended_line"]:
        m = re.search(r'relay="([^"]*)"', srv["ended_line"])
        print("server summary:", m.group(1) if m else srv["ended_line"][:200])
    print()

    timeline = []
    for ts, what in app["marks"]:
        timeline.append((rel(ts), "app ", what))
    for t, kind, a, b in app["events"]:
        timeline.append((t, "app ", f"{kind} a={a} b={b}"))
    for ts, what in app["windows"]:
        timeline.append((rel(ts), "app ", what[:140]))
    if srv:
        timeline.append((srel(srv["bridged"]), "srv ", "bridged (pumps start)"))
        for ts, d in srv["relay"]:
            keys = ["dir", "read_2s", "skew_ms", "early_max_ms", "late_max_ms", "backlog_pkts", "backlog_ms",
                    "first_rtp_ms", "answer_to_pump_ms", "max_gap_ms", "max_burst", "burst_ms"]
            timeline.append((srel(ts), "srv ", " ".join(f"{k}={d[k]}" for k in keys if k in d)))
        if args.trace_dir and srv:
            import glob
            import os
            safe = re.sub(r"[^A-Za-z0-9._-]", "_", srv["id"])
            for path in sorted(glob.glob(os.path.join(args.trace_dir, safe + "-*.tsv"))):
                name = os.path.basename(path)
                bursts, gaps = trace_bursts(path)
                off = srel(srv["bridged"])
                for t, n, s0, s1 in bursts:
                    timeline.append((off + t, "trc ", f"{name}: burst of {n} packets seq {s0}..{s1}"))
                for t, ms in gaps:
                    timeline.append((off + t, "trc ", f"{name}: arrival gap {ms:.0f} ms"))
    timeline.sort(key=lambda x: x[0])
    for t, who, what in timeline:
        print(f"{t:8.3f}s {who} {what}")


if __name__ == "__main__":
    main()
