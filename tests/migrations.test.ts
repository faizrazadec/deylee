/**
 * Tests for the migration *decision* — which migrations are pending, and the refusal
 * to open a file written by a newer build.
 *
 * These do not touch SQLite, and that is not a preference. `better-sqlite3` in this
 * repo is rebuilt against Electron's ABI by the `postinstall`
 * (`electron-builder install-app-deps`), so loading it from plain Node — which is what
 * Vitest runs — fails with `NODE_MODULE_VERSION 148 … requires 147`. The same is true
 * on CI, where `npm ci` rebuilds it the same way before `npm test`. A test that opened
 * a real `:memory:` database would therefore fail everywhere rather than prove
 * anything, so what is exercised here is exactly what can be exercised honestly:
 * `runMigrations` runs for real, against a recording double of the four `Database`
 * methods it calls. The SQL itself is verified by using the app.
 *
 * `migrations.ts` imports `better-sqlite3` as a *type* only, so importing it here loads
 * no native code and no Electron module.
 */

import type Database from 'better-sqlite3';
import { describe, expect, it } from 'vitest';
import {
  CURRENT_SCHEMA_VERSION,
  SchemaTooNewError,
  runMigrations,
} from '../src/main/db/migrations';

interface VersionRow {
  version: number;
}

interface StatementStub {
  get(): VersionRow | undefined;
  run(version: number): void;
}

/**
 * Records the calls `runMigrations` makes, so a test can assert *that nothing was
 * written* as precisely as it asserts what was.
 *
 * The cast to `Database.Database` goes through `unknown` because the real interface is
 * some forty members wide and this stands in for four of them. Every call site is still
 * typechecked against the real declarations — only the implementation is doubled.
 */
class FakeDatabase {
  /** Every `exec` in order — the bootstrap DDL first, then any migration's. */
  readonly execs: string[] = [];
  /** Versions written to `schema_version`, in the order they were stamped. */
  readonly stamped: number[] = [];
  /** How many times the version row was cleared. */
  clears = 0;
  /** How many times a transaction body was run. */
  transactions = 0;

  private version: number | null;

  constructor(storedVersion: number | null) {
    this.version = storedVersion;
  }

  asDatabase(): Database.Database {
    return this as unknown as Database.Database;
  }

  /** Every write this double saw, whether or not it was inside a transaction. */
  get writes(): number {
    return this.stamped.length + this.clears;
  }

  exec(sql: string): void {
    this.execs.push(sql);
  }

  prepare(sql: string): StatementStub {
    if (sql.startsWith('SELECT')) {
      return {
        get: (): VersionRow | undefined =>
          this.version === null ? undefined : { version: this.version },
        run: (): void => {
          throw new Error(`unexpected run() on a SELECT: ${sql}`);
        },
      };
    }

    if (sql.startsWith('DELETE')) {
      return {
        get: (): VersionRow | undefined => undefined,
        run: (): void => {
          this.clears += 1;
          this.version = null;
        },
      };
    }

    if (sql.startsWith('INSERT')) {
      return {
        get: (): VersionRow | undefined => undefined,
        run: (version: number): void => {
          this.stamped.push(version);
          this.version = version;
        },
      };
    }

    throw new Error(`unexpected statement: ${sql}`);
  }

  transaction(body: () => void): () => void {
    return (): void => {
      this.transactions += 1;
      body();
    };
  }
}

describe('runMigrations', () => {
  it('bootstraps schema_version before reading it', () => {
    const fake = new FakeDatabase(null);
    runMigrations(fake.asDatabase());

    expect(fake.execs[0]).toContain('CREATE TABLE IF NOT EXISTS schema_version');
  });

  it('migrates an empty file up to the current version', () => {
    const fake = new FakeDatabase(null);
    runMigrations(fake.asDatabase());

    expect(fake.stamped).toEqual([CURRENT_SCHEMA_VERSION]);
    expect(fake.transactions).toBe(1);
    // Bootstrap, plus at least one migration's DDL.
    expect(fake.execs.length).toBeGreaterThan(1);
  });

  it('migrates a database stamped below the current version', () => {
    const fake = new FakeDatabase(CURRENT_SCHEMA_VERSION - 1);
    runMigrations(fake.asDatabase());

    expect(fake.stamped).toEqual([CURRENT_SCHEMA_VERSION]);
    expect(fake.transactions).toBe(1);
  });

  it('stamps versions in ascending order, one per migration', () => {
    const fake = new FakeDatabase(null);
    runMigrations(fake.asDatabase());

    const ascending = [...fake.stamped].sort((a, b) => a - b);
    expect(fake.stamped).toEqual(ascending);
    expect(fake.stamped[fake.stamped.length - 1]).toBe(CURRENT_SCHEMA_VERSION);
  });

  it('writes nothing when the database is already current', () => {
    const fake = new FakeDatabase(CURRENT_SCHEMA_VERSION);
    runMigrations(fake.asDatabase());

    expect(fake.writes).toBe(0);
    expect(fake.transactions).toBe(0);
    expect(fake.execs).toHaveLength(1); // the bootstrap only
  });

  it('is a no-op on a second run', () => {
    const first = new FakeDatabase(null);
    runMigrations(first.asDatabase());

    const second = new FakeDatabase(CURRENT_SCHEMA_VERSION);
    runMigrations(second.asDatabase());

    expect(second.writes).toBe(0);
    expect(second.transactions).toBe(0);
  });

  it('refuses a database written by a newer build', () => {
    const fake = new FakeDatabase(CURRENT_SCHEMA_VERSION + 3);

    expect(() => runMigrations(fake.asDatabase())).toThrow(SchemaTooNewError);
  });

  it('refuses a database exactly one version ahead', () => {
    const fake = new FakeDatabase(CURRENT_SCHEMA_VERSION + 1);

    expect(() => runMigrations(fake.asDatabase())).toThrow(SchemaTooNewError);
  });

  it('carries both versions on the refusal', () => {
    const stored = CURRENT_SCHEMA_VERSION + 2;
    const fake = new FakeDatabase(stored);

    try {
      runMigrations(fake.asDatabase());
      expect.unreachable('runMigrations should have thrown');
    } catch (error: unknown) {
      expect(error).toBeInstanceOf(SchemaTooNewError);
      if (!(error instanceof SchemaTooNewError)) return;

      expect(error.storedVersion).toBe(stored);
      expect(error.supportedVersion).toBe(CURRENT_SCHEMA_VERSION);
      expect(error.name).toBe('SchemaTooNewError');
      expect(error.message).toContain(String(stored));
      expect(error.message).toContain(String(CURRENT_SCHEMA_VERSION));
    }
  });

  it('refuses before writing anything', () => {
    const fake = new FakeDatabase(CURRENT_SCHEMA_VERSION + 1);

    expect(() => runMigrations(fake.asDatabase())).toThrow(SchemaTooNewError);
    // The whole point of the guard: the newer file is left exactly as it was.
    expect(fake.writes).toBe(0);
    expect(fake.transactions).toBe(0);
    expect(fake.execs).toHaveLength(1); // the bootstrap only — no migration DDL
  });
});
