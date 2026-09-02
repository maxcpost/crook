---
name: seed-checker
description: Verify a seeded environment before the first deploy
disable-model-invocation: true
---

# Seed check

The directory is what names the command. The `name:` field above says
`seed-checker` and moves nothing.

1. Confirm every table has a row count above zero.
2. Confirm the ledger head matches the segment index.
3. Confirm the wire version is the one the spec names.
