#!/usr/bin/env python3
"""
itch_replay_prep.py — prepare a real-data replay for the FPGA feed handler.

One pass over a NASDAQ TotalView-ITCH 5.0 BinaryFILE (.gz or raw), where every
message is preceded by a 2-byte big-endian length. It:

  1. finds the stock locate of SYMBOL from its Stock Directory ('R') message;
  2. writes the replay stream (same 2-byte-length format) containing every
     message of that stock plus a random sample of other stocks' messages
     (to exercise the decoder's stock-locate filter);
  3. runs an INDEPENDENT reference model of what the hardware should do and
     writes the BBO trace: one line each time the BBO changes.

The reference model mirrors the hardware's documented behaviour, not its code:
  - ref table: 4-way set-associative, set = low 12 bits of the order ref.
    An Add into a full set is dropped (overflow); later ops on it miss.
  - book: 1024 price levels of TICK from BASE. Orders outside the window live
    in the ref table but never touch the book (or the BBO).
  - E / C / X reduce an order by the executed/cancelled shares; D removes it.
  - U = Delete(original ref), then Add(new ref) on the original's side. If the
    original is missing, the Add half is skipped (and counts as an overflow).

Trace line format (decimal), identical to feed_handler_replay_tb.sv:
    bid_valid bid_px bid_qty offer_valid offer_px offer_qty
with px and qty printed as 0 when that side is empty.

Usage:
    python3 scripts/itch_replay_prep.py data/20191230.BX_ITCH_50.gz MSFT --base 1520000 --out-prefix data/msft
    python3 itch_replay_prep.py FILE SYMBOL --base B [--max-ours N]
                                [--other-rate 0.001] [--seed 1] [--out-prefix msft]
"""

import argparse
import gzip
import random
import struct
import sys
from collections import Counter

LEVELS = 1024          # book window size (levels)
TICK = 100             # $0.01 in ITCH price units (4 implied decimals)
INDEX_BITS = 12        # ref table sets = 2**12
WAYS = 4

DECODED = set(b"AFECXDU")


def open_itch(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rb")
    return open(path, "rb")


def read_messages(f):
    """Yield (raw_with_length_prefix, message_bytes) for each message."""
    read = f.read
    while True:
        hdr = read(2)
        if len(hdr) < 2:
            return
        (n,) = struct.unpack(">H", hdr)
        msg = read(n)
        if len(msg) < n:
            raise ValueError("truncated message at end of file")
        yield hdr + msg, msg


class HwModel:
    """Reference model of ref_table + book as the hardware is specified."""

    def __init__(self, base):
        self.base = base
        self.orders = {}                      # ref -> [side, price, shares]
        self.set_count = Counter()            # set index -> live orders
        self.qty = {b"B": [0] * LEVELS, b"S": [0] * LEVELS}
        self.best = {b"B": None, b"S": None}  # best level per side
        self.stats = Counter()
        self.first_overflow = None
        self.max_set = 0

    # ---------- book ----------
    def level_of(self, price):
        d = price - self.base
        if d < 0 or d >= LEVELS * TICK:
            return None
        if d % TICK:
            self.stats["off_tick_prices"] += 1
        return d // TICK

    def _rescan(self, side):
        q = self.qty[side]
        rng = range(LEVELS - 1, -1, -1) if side == b"B" else range(LEVELS)
        self.best[side] = next((l for l in rng if q[l]), None)

    def book_add(self, side, price, sh):
        l = self.level_of(price)
        if l is None:
            return
        self.qty[side][l] += sh
        b = self.best[side]
        if b is None or (l > b if side == b"B" else l < b):
            self.best[side] = l

    def book_sub(self, side, price, sh):
        l = self.level_of(price)
        if l is None:
            return
        q = self.qty[side]
        q[l] -= sh
        if q[l] < 0:
            self.stats["negative_level_qty"] += 1
            q[l] = 0
        if q[l] == 0 and l == self.best[side]:
            self._rescan(side)

    def bbo(self):
        out = []
        for side in (b"B", b"S"):
            l = self.best[side]
            if l is None:
                out += [0, 0, 0]
            else:
                out += [1, self.base + l * TICK, self.qty[side][l]]
        return tuple(out)

    # ---------- ref table ----------
    def _overflow(self, idx):
        self.stats["overflows"] += 1
        if self.first_overflow is None:
            self.first_overflow = idx

    def add(self, ref, side, price, sh, idx):
        s = ref & ((1 << INDEX_BITS) - 1)
        if self.set_count[s] >= WAYS:
            self._overflow(idx)
            self.stats["adds_dropped"] += 1
            return
        self.set_count[s] += 1
        self.max_set = max(self.max_set, self.set_count[s])
        self.orders[ref] = [side, price, sh]
        if self.level_of(price) is None:
            self.stats["adds_out_of_window"] += 1
        self.book_add(side, price, sh)

    def _free(self, ref):
        del self.orders[ref]
        self.set_count[ref & ((1 << INDEX_BITS) - 1)] -= 1

    def reduce(self, ref, sh):
        o = self.orders.get(ref)
        if o is None:
            self.stats["reduce_miss"] += 1
            return
        if sh > o[2]:
            self.stats["over_reduce"] += 1
            sh = o[2]
        o[2] -= sh
        self.book_sub(o[0], o[1], sh)
        if o[2] == 0:
            self._free(ref)

    def delete(self, ref):
        """Returns the side of the deleted order, or None on a miss."""
        o = self.orders.get(ref)
        if o is None:
            self.stats["delete_miss"] += 1
            return None
        self.book_sub(o[0], o[1], o[2])
        self._free(ref)
        return o[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("itch_file")
    ap.add_argument("symbol")
    ap.add_argument("--base", type=int, required=True,
                    help="window base price, ITCH units (4 decimals), e.g. 1520000 = $152.00")
    ap.add_argument("--max-ours", type=int, default=0,
                    help="stop after this many of the stock's messages (0 = whole file)")
    ap.add_argument("--other-rate", type=float, default=0.001,
                    help="fraction of other stocks' messages to include")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out-prefix", default=None)
    args = ap.parse_args()

    sym = args.symbol.upper().encode().ljust(8, b" ")
    prefix = args.out_prefix or args.symbol.lower()
    rng = random.Random(args.seed)
    hw = HwModel(args.base)

    locate = None
    n_total = n_ours = n_others = 0
    types_ours = Counter()
    add_prices = []
    last_bbo = hw.bbo()
    n_trace = 0

    with open_itch(args.itch_file) as f, \
         open(prefix + "_stream.bin", "wb") as stream, \
         open(prefix + "_ref_bbo.txt", "w") as trace:

        def log_bbo():
            nonlocal last_bbo, n_trace
            b = hw.bbo()
            if b != last_bbo:
                trace.write("%d %d %d %d %d %d\n" % b)
                last_bbo = b
                n_trace += 1

        for raw, msg in read_messages(f):
            n_total += 1
            t = msg[0]
            loc = (msg[1] << 8) | msg[2]

            if locate is None and t == 0x52 and msg[11:19] == sym:   # 'R'
                locate = loc
                print("%s: stock locate = %d (found at message %d)"
                      % (args.symbol.upper(), locate, n_total))

            if locate is not None and loc == locate:
                n_ours += 1
                types_ours[chr(t)] += 1
                stream.write(raw)

                if t in DECODED:
                    ref = int.from_bytes(msg[11:19], "big")
                    if t in (0x41, 0x46):                       # A, F
                        side = msg[19:20]
                        sh, px = struct.unpack(">I", msg[20:24])[0], struct.unpack(">I", msg[32:36])[0]
                        add_prices.append(px)
                        hw.add(ref, side, px, sh, n_ours)
                        log_bbo()
                    elif t in (0x45, 0x43, 0x58):               # E, C, X
                        sh = struct.unpack(">I", msg[19:23])[0]
                        hw.reduce(ref, sh)
                        log_bbo()
                    elif t == 0x44:                             # D
                        hw.delete(ref)
                        log_bbo()
                    elif t == 0x55:                             # U
                        new_ref = int.from_bytes(msg[19:27], "big")
                        sh = struct.unpack(">I", msg[27:31])[0]
                        px = struct.unpack(">I", msg[31:35])[0]
                        side = hw.delete(ref)
                        log_bbo()                                # state after the Delete half
                        if side is None:
                            hw.stats["replace_add_skipped"] += 1
                            hw._overflow(n_ours)
                        else:
                            add_prices.append(px)
                            hw.add(new_ref, side, px, sh, n_ours)
                            log_bbo()

                if args.max_ours and n_ours >= args.max_ours:
                    break
            elif loc != locate and rng.random() < args.other_rate:
                n_others += 1
                stream.write(raw)

    if locate is None:
        sys.exit("symbol %s not found in any R message" % args.symbol)

    # ---------- summary ----------
    print()
    print("messages read           : %d" % n_total)
    print("%s messages            : %d   %s" % (args.symbol.upper(), n_ours,
          " ".join("%s=%d" % kv for kv in sorted(types_ours.items()))))
    print("other-stock messages    : %d (sampled at %g)" % (n_others, args.other_rate))
    print("stream bytes            : written to %s_stream.bin" % prefix)
    print("BBO changes (reference) : %d, written to %s_ref_bbo.txt" % (n_trace, prefix))
    print()
    if add_prices:
        s = sorted(add_prices)
        pct = lambda p: s[min(len(s) - 1, int(p * len(s)))]
        print("add prices ($)          : min %.2f  1%% %.2f  median %.2f  99%% %.2f  max %.2f"
              % (s[0] / 1e4, pct(0.01) / 1e4, pct(0.5) / 1e4, pct(0.99) / 1e4, s[-1] / 1e4))
        print("window ($)              : %.2f .. %.2f" % (args.base / 1e4, (args.base + LEVELS * TICK) / 1e4))
    print("adds out of window      : %d" % hw.stats["adds_out_of_window"])
    print("ref-table overflows     : %d (adds dropped %d, replace-adds skipped %d), max set occupancy %d/%d"
          % (hw.stats["overflows"], hw.stats["adds_dropped"], hw.stats["replace_add_skipped"],
             hw.max_set, WAYS))
    if hw.first_overflow is not None:
        print("first overflow at       : %s message #%d -> book_degraded goes high"
              % (args.symbol.upper(), hw.first_overflow))
    for k in ("reduce_miss", "delete_miss", "over_reduce", "negative_level_qty", "off_tick_prices"):
        if hw.stats[k]:
            print("%-24s: %d" % (k.replace("_", " "), hw.stats[k]))
    print("live orders at the end  : %d" % len(hw.orders))


if __name__ == "__main__":
    main()
