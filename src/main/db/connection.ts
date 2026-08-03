/**
 * The one SQLite connection the app owns.
 *
 * The pragma choices are deliberate:
 *  - WAL keeps readers from blocking the writer, and is what makes the online
 *    backup in `BackupService` safe to run while the timer is still ticking.
 *  - `synchronous = NORMAL` is the correct pairing with WAL: a power loss can cost
 *    the last commit, never the file. FULL would fsync on every 30s heartbeat.
 *  - `foreign_keys` is off by default in SQLite, so `ON DELETE CASCADE` from
 *    `segments` to `days` only works if we turn it on for every connection.
 *  - `busy_timeout` covers the short lock the backup and WAL checkpoints take.
 */

import Database from 'better-sqlite3';

export function openDatabase(filePath: string): Database.Database {
  const db = new Database(filePath);

  // journal_mode is a property of the file itself, so it is applied first — before
  // anything has a chance to open a transaction in the old rollback journal mode.
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.pragma('busy_timeout = 5000');
  db.pragma('synchronous = NORMAL');

  return db;
}
