/**
 * Database backup.
 *
 * The live database runs in WAL mode, so the `.sqlite` file on disk is *not* a
 * complete snapshot — recent commits may still live only in the `-wal` sidecar, and a
 * plain file copy would produce a database missing the user's last few hours. SQLite's
 * online backup API reads a consistent view through a real connection instead, which
 * is safe to run while the app keeps writing.
 *
 * `better-sqlite3` exposes it as an async `db.backup()` that steps the copy in chunks,
 * so the main process stays responsive on a large file.
 */

import { dialog } from 'electron';
import type { BrowserWindow, SaveDialogOptions } from 'electron';
import Database from 'better-sqlite3';

import { todayKey } from '@shared/time';
import type { FileWriteResult } from '@shared/types';

export async function backupDatabase(
  dbPath: string,
  parent: BrowserWindow | null,
): Promise<FileWriteResult> {
  const options: SaveDialogOptions = {
    title: 'Back up Dayly data',
    defaultPath: `dayly-backup-${todayKey()}.sqlite`,
    filters: [{ name: 'SQLite database', extensions: ['sqlite'] }],
    properties: ['createDirectory', 'showOverwriteConfirmation'],
  };

  // Parent-modal when we have a window, so the dialog cannot be lost behind it.
  const chosen =
    parent === null
      ? await dialog.showSaveDialog(options)
      : await dialog.showSaveDialog(parent, options);

  if (chosen.canceled || chosen.filePath.length === 0) {
    return { ok: false, cancelled: true };
  }

  let source: Database.Database | null = null;
  try {
    source = new Database(dbPath, { readonly: true, fileMustExist: true });
    await source.backup(chosen.filePath);
    return { ok: true, path: chosen.filePath };
  } catch (error) {
    return { ok: false, cancelled: false, message: describeError(error) };
  } finally {
    // A second connection left open would pin the WAL; close it whatever happened.
    try {
      source?.close();
    } catch {
      // Already closed or never opened — nothing left to release.
    }
  }
}

function describeError(error: unknown): string {
  if (error instanceof Error && error.message.length > 0) return error.message;
  return 'The backup could not be written.';
}
