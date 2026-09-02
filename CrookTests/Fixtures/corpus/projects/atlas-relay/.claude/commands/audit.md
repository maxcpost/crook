---
description: Audit the ledger for unbalanced entries
---

# /audit

Walk every ledger segment and report any entry whose signature does not verify.

- Read the segment index first.
- Report in the order segments were written, never sorted.
- Stop at the first unreadable segment and say which one.
