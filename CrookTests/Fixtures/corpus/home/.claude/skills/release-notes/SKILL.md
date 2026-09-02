---
name: release-notes
description: Turn a changelog into release notes a human will actually read
---

# Release notes  

Status markers used in this package: ✅ shipped, 🚧 in progress, 🗓️ scheduled.

Read the changelog, group by surface, and write one line per change.

## Steps

1. Read `references/api.md` for the surface list.
2. Follow `commands/decide.md` to pick what is worth mentioning.
3. Fill in `templates/entry.md` once per surface.

## Do not do this

```bash
cp /Users/nobody-here/Projects/atlas-relay/scripts/seed.sh ./scripts/
./scripts/seed.sh --env prod
```

That block is an example of what went wrong last time, not an instruction.
