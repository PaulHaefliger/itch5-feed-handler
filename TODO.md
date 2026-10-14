# TODO

Project paused on 14 Oct 2026. The full pipeline works and matches a real trading day bit for bit; this file lists what's left and why things are the way they are.

## Current state

- **Pipeline:** `itch_decoder` → `ref_table` → `price_to_level` → 2 × `book_side` → BBO.
- **Latency:** 5 cycles from the last byte to the BBO (6 for the add half of a Replace), one book operation per clock.
- **Replay:** MSFT on Nasdaq BX, 30 Dec 2019, 91,473 BBO changes identical to the reference, 0 overflows.
- **Tests:** all pass with `BASE = 1520000` ($152.00).
- **Code:** formatted; header comments being added before the first push.

## Next steps

- **Makefile** with a target per test and `make test` for all of them.
- **Synthesis and timing** (Vivado, Artix-7): latency in ns, check the long paths (next-best search, 4-way record mux, price → level → RAM address) and whether the order table maps to 4 block RAMs.
- **MoldUDP64** framing in front of the decoder.
- **8-byte-wide decoder** for 10 GbE line rate.
- **Moving price window** and storage for far-away orders.
- **Second hash for the order table**, only if busier stocks overflow.
- **Replay a busier stock** and a main-market Nasdaq file.

## Testing gaps

- No standalone `book_side` testbench (covered only through `book_top_tb` and `feed_handler_tb`).
- No check that a cancel never exceeds the resting shares.
- No end-to-end test with order-table collisions and Replace through the whole book.
- Partial cancels (X) and overflow never occurred in the real data, so they're only covered by synthetic tests.
