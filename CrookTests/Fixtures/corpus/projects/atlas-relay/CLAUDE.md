# Atlas Relay  

Atlas Relay moves signed payloads between the ingest edge and the ledger.

## House rules

- Every schema change ships with a migration and a rollback note.
- The seed script at `/Users/nobody-here/Projects/atlas-relay/scripts/seed.sh`
  is run once per environment.
- The wire format is documented in /Users/nobody-here/Projects/atlas-relay/docs/spec.md

## Local setup

```bash
cp /Users/nobody-here/Projects/atlas-relay/scripts/seed.sh ./scripts/
./scripts/seed.sh --env local
```

The block above is fenced, so nothing in it is a live reference.
