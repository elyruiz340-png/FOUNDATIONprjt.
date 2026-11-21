# EDMEL Migration Recovery Archive

## Purpose
Read-only historical recovery copy of SQL recorded in the active Supabase project's `supabase_migrations.schema_migrations` ledger.

## Contents
- `archive/`: 99 SQL files reconstructed from each ledger row's `statements` array.
- `migration-manifest.csv`: migration metadata, SQL integrity fields, and source reconciliation status.
- Kept outside `supabase/migrations/` so these historical files are not mistaken for pending migrations.

## Recovery provenance
- Supabase project reference: `isqcuycjrbjtmqhzckvb`
- GitHub repository: `elyruiz340-png/FOUNDATIONprjt.`
- Branch: `test`
- Ledger rows recovered: 99
- Total SQL characters: 492208
- Tracked migration files compared: 18
- Exact one-to-one matches: 13
- Embedded source representations: 1
- Partial source representations: 1
- No complete one-to-one source match / mismatch: 84

## Safety warning
**Do not execute these files as migrations or copy them blindly into `supabase/migrations/`.** They represent SQL already recorded as applied in the database. Replaying them may fail or alter existing schema/data. This archive does not execute SQL, alter Supabase, reconcile migration history, or certify replay safety.

## Manifest fields
- `sql_length`: character length of the reconstructed SQL string.
- `sql_md5`: PostgreSQL `md5(array_to_string(statements, E'\\n'))`; integrity reference only, not a cryptographic signature.
- `exact`: tracked source matches recovered SQL after line-ending normalization and trimming.
- `embedded`: recovered SQL is represented inside a combined source file.
- `partial`: tracked source is only a partial representation of the applied record.
- `missing_or_mismatch`: no complete one-to-one tracked source was verified.

This archive is a recovery aid for review and future migration reconciliation only.
