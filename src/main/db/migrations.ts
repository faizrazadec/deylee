/**
 * Schema creation and versioned migration.
 *
 * Migrations are an ordered, append-only list. Each one is gated on the stored
 * version and every statement is `IF NOT EXISTS`, so running this against an
 * up-to-date file is a no-op and running it against a half-migrated one — the app
 * was killed mid-upgrade — cannot corrupt anything: the whole batch commits or
 * rolls back as a unit.
 *
 * No table here stores a total. Totals are derived from `segments` by
 * `@domain/duration`, which is what keeps them correct after a crash or an edit.
 *
 * Migrations only ever go forwards. A file written by a newer build is refused
 * outright — see `SchemaTooNewError`.
 */

import type Database from 'better-sqlite3';

/** Bump this in lock-step with a new entry in `MIGRATIONS`. */
export const CURRENT_SCHEMA_VERSION: number = 1;

/**
 * The database on disk was written by a newer build of Dayly than this one.
 *
 * Opening it anyway is the quiet way to lose history: this build would write rows
 * shaped for an older schema, ignore columns it does not know about, and let a
 * later `DROP`/rebuild take the newer ones with it. There is no down-migration to
 * fall back on, so the only safe answer is to not open the file at all. The main
 * process catches this and refuses to start with an explanation.
 */
export class SchemaTooNewError extends Error {
  readonly storedVersion: number;
  readonly supportedVersion: number;

  constructor(storedVersion: number, supportedVersion: number) {
    super(
      `The database was created by a newer version of Dayly (schema v${storedVersion}); ` +
        `this build supports up to v${supportedVersion}.`,
    );
    this.name = 'SchemaTooNewError';
    this.storedVersion = storedVersion;
    this.supportedVersion = supportedVersion;
  }
}

interface Migration {
  readonly version: number;
  up(db: Database.Database): void;
}

interface SchemaVersionRow {
  version: number;
}

const MIGRATIONS: readonly Migration[] = [
  {
    version: 1,
    up(db: Database.Database): void {
      db.exec(`
        CREATE TABLE IF NOT EXISTS days (
          id             INTEGER PRIMARY KEY AUTOINCREMENT,
          date           TEXT    NOT NULL UNIQUE,
          created_at     INTEGER NOT NULL,
          ended_at       INTEGER,
          target_minutes INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS segments (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          day_id     INTEGER NOT NULL REFERENCES days(id) ON DELETE CASCADE,
          type       TEXT    NOT NULL CHECK (type IN ('work','break')),
          started_at INTEGER NOT NULL,
          ended_at   INTEGER,
          note       TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_segments_day ON segments(day_id, started_at);

        -- Partial index: the open-segment lookup runs on every snapshot, and there
        -- is at most one matching row in the whole table.
        CREATE INDEX IF NOT EXISTS idx_segments_open ON segments(ended_at) WHERE ended_at IS NULL;

        CREATE TABLE IF NOT EXISTS app_state (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
      `);
    },
  },
];

export function runMigrations(db: Database.Database): void {
  // Bootstrapped outside the migration list because reading the current version
  // requires the table to already exist.
  db.exec('CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)');

  const current = readSchemaVersion(db);

  // Checked before anything is applied and before any write, so a downgrade leaves
  // the file exactly as the newer build left it.
  if (current > CURRENT_SCHEMA_VERSION) {
    throw new SchemaTooNewError(current, CURRENT_SCHEMA_VERSION);
  }

  const pending = MIGRATIONS.filter(
    (migration) => migration.version > current && migration.version <= CURRENT_SCHEMA_VERSION,
  ).sort((a, b) => a.version - b.version);

  // Already up to date.
  if (pending.length === 0) return;

  const clearVersion = db.prepare('DELETE FROM schema_version');
  const writeVersion = db.prepare<[number]>('INSERT INTO schema_version (version) VALUES (?)');

  db.transaction(() => {
    for (const migration of pending) {
      migration.up(db);
      clearVersion.run();
      writeVersion.run(migration.version);
    }
  })();
}

/** 0 means "empty file" — every migration is pending. */
function readSchemaVersion(db: Database.Database): number {
  const row = db
    .prepare<[], SchemaVersionRow>('SELECT version FROM schema_version ORDER BY version DESC LIMIT 1')
    .get();
  return row === undefined ? 0 : row.version;
}
