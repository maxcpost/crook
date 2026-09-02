---
description: Cut a release and push the tag
argument-hint: [version]
---

# /ship  

1. Confirm the tree is clean.
2. Run the seed script at `/Users/nobody-here/Projects/atlas-relay/scripts/seed.sh` once.
3. Copy the checklist from `/Users/nobody-here/Notes/Field Notes/atlas/rollout.md`.
4. Tag, push, and announce.

Do not run `~/venvs/atlas/bin/pytest tests/ -q` here; CI owns the suite.
