/**
 * The IPC trust boundary.
 *
 * Everything arriving from a renderer is `unknown`. A renderer is only as trustworthy
 * as the page it happens to be running, so nothing reaches the repository before it has
 * been narrowed here — shapes, finite numbers, date keys and enum membership.
 *
 * Handlers also all but never throw. An `invoke` rejection surfaces in the renderer as
 * an opaque Error with no code, which the UI cannot act on, so failures are returned as
 * values instead: `MutationResult` where the contract has one, and an unsurprising
 * fallback everywhere else.
 *
 * `prefs:set` is the one deliberate exception, explained where it is registered: its
 * contract carries no failure case, so the only fallback it could return is a set of
 * preferences that reads as a successful save.
 */

import { BrowserWindow, app, dialog, ipcMain } from 'electron';
import type { SaveDialogOptions } from 'electron';
import { writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

import { EVENT, INVOKE } from '@shared/ipc';
import type { HistoryInvalidated } from '@shared/ipc';
import { dateKeyOf, isDateKey, todayKey } from '@shared/time';
import type {
  DateKey,
  DateRange,
  DayDetail,
  EpochMs,
  ExportFormat,
  FileWriteResult,
  IdleChoice,
  MiniWindowPosition,
  MutationResult,
  PendingRecovery,
  PlatformInfo,
  Preferences,
  RangeSummary,
  RecoveryChoice,
  Segment,
  SegmentType,
  TimerSnapshot,
  UpdateInfo,
  UpdateStatus,
  WakeChoice,
  WindowKind,
} from '@shared/types';
import { summariseRange } from '@domain/aggregate';
import { hoursToMinutes } from '@domain/duration';
import { splitAtMidnight } from '@domain/midnight';
import { validateSegment } from '@domain/overlap';
import type { Repository } from '@main/db/repository';
import type { Platform } from '@main/platform/Platform';
import { DEFAULT_PREFERENCES } from '@main/store/preferences';
import type { PreferencesStore } from '@main/store/preferences';
import { backupDatabase } from '@main/services/BackupService';
import { buildCsv, buildJson } from '@main/services/ExportService';
import type { TimerService } from '@main/services/TimerService';
import type { UpdateService } from '@main/services/UpdateService';
import type { WindowManager } from '@main/windows/WindowManager';

export interface IpcHandlerDeps {
  repo: Repository;
  timer: TimerService;
  prefs: PreferencesStore;
  windows: WindowManager;
  platform: Platform;
  updates: UpdateService;
  dbPath: string;
  getPendingRecovery: () => PendingRecovery | null;
  resolveRecovery: (choice: RecoveryChoice) => TimerSnapshot;
  resolveIdle: (promptId: string, choice: IdleChoice) => TimerSnapshot;
  resolveWake: (promptId: string, choice: WakeChoice) => TimerSnapshot;
  platformInfo: () => PlatformInfo;
  /** Applies the OS login item. Rejects when the OS refuses; the caller must not persist then. */
  setLoginItemEnabled: (enabled: boolean) => Promise<void>;
}

/* -------------------------------------------------------------------------- */
/* Narrowing helpers                                                           */
/* -------------------------------------------------------------------------- */

const SEGMENT_TYPES: readonly SegmentType[] = ['work', 'break'];
const WINDOW_KINDS: readonly WindowKind[] = ['panel', 'mini', 'history', 'settings'];
const EXPORT_FORMATS: readonly ExportFormat[] = ['csv', 'json'];
const RECOVERY_CHOICES: readonly RecoveryChoice[] = ['resume', 'close-at-heartbeat', 'discard'];
const IDLE_CHOICES: readonly IdleChoice[] = ['keep', 'discard'];
const WAKE_CHOICES: readonly WakeChoice[] = ['resume', 'count-as-break'];
const THEMES: readonly Preferences['theme'][] = ['system', 'light', 'dark'];
const WEEK_STARTS: readonly Preferences['weekStartsOn'][] = [0, 1];

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function asFinite(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

/** Row ids are positive integers; anything else cannot name a stored segment. */
function asId(value: unknown): number | null {
  const numeric = asFinite(value);
  return numeric !== null && Number.isInteger(numeric) && numeric > 0 ? numeric : null;
}

function asDateKey(value: unknown): DateKey | null {
  return typeof value === 'string' && isDateKey(value) ? value : null;
}

function asRange(value: unknown): DateRange | null {
  if (!isRecord(value)) return null;
  const from = asDateKey(value.from);
  const to = asDateKey(value.to);
  if (from === null || to === null) return null;
  return { from, to };
}

/**
 * Returns the matching member of `allowed` rather than a cast, so the literal type
 * comes from the allow-list instead of from an assertion about the input.
 */
function pickLiteral<T extends string | number>(value: unknown, allowed: readonly T[]): T | null {
  for (const candidate of allowed) {
    if (candidate === value) return candidate;
  }
  return null;
}

/**
 * `undefined` means "leave the note untouched", `null` clears it, and `false` marks a
 * payload that was not a note at all. Blank text is stored as `null` so the database
 * has one representation of "no note".
 */
function asNote(value: unknown): string | null | undefined | false {
  if (value === undefined) return undefined;
  if (value === null) return null;
  if (typeof value !== 'string') return false;
  const trimmed = value.trim();
  return trimmed.length === 0 ? null : trimmed;
}

function asMiniWindowPositions(value: unknown): Record<string, MiniWindowPosition> | null {
  if (!isRecord(value)) return null;
  const positions: Record<string, MiniWindowPosition> = {};
  for (const [displayId, entry] of Object.entries(value)) {
    if (!isRecord(entry)) return null;
    const x = asFinite(entry.x);
    const y = asFinite(entry.y);
    if (x === null || y === null) return null;
    positions[displayId] = { x, y };
  }
  return positions;
}

function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function logFailure(channel: string, error: unknown): void {
  console.error(`[dayly] ipc ${channel} failed:`, error);
}

/** A malformed payload never reaches the database; the renderer gets a reason instead. */
function invalidPayload(message: string): { ok: false; code: 'invalid-range'; message: string } {
  return { ok: false, code: 'invalid-range', message };
}

/* -------------------------------------------------------------------------- */
/* Segment payloads                                                            */
/* -------------------------------------------------------------------------- */

/** A fully resolved segment, ready to be split and stored. */
interface SegmentWrite {
  type: SegmentType;
  startedAt: EpochMs;
  endedAt: EpochMs | null;
  note: string | null;
}

/** An edit where an absent field means "leave it alone". */
interface ParsedUpdate {
  id: number;
  type?: SegmentType;
  startedAt?: EpochMs;
  endedAt?: EpochMs | null;
  note?: string | null;
}

function parseCreate(payload: unknown): { date: DateKey; write: SegmentWrite } | null {
  if (!isRecord(payload)) return null;
  const date = asDateKey(payload.date);
  const input = payload.input;
  if (date === null || !isRecord(input)) return null;

  const type = pickLiteral(input.type, SEGMENT_TYPES);
  const startedAt = asFinite(input.startedAt);
  const endedAt = asFinite(input.endedAt);
  const note = asNote(input.note);
  if (type === null || startedAt === null || endedAt === null || note === false) return null;

  return { date, write: { type, startedAt, endedAt, note: note ?? null } };
}

function parseUpdate(payload: unknown): ParsedUpdate | null {
  if (!isRecord(payload)) return null;
  const id = asId(payload.id);
  if (id === null) return null;

  const parsed: ParsedUpdate = { id };

  if (payload.type !== undefined) {
    const type = pickLiteral(payload.type, SEGMENT_TYPES);
    if (type === null) return null;
    parsed.type = type;
  }
  if (payload.startedAt !== undefined) {
    const startedAt = asFinite(payload.startedAt);
    if (startedAt === null) return null;
    parsed.startedAt = startedAt;
  }
  if (payload.endedAt !== undefined) {
    if (payload.endedAt === null) {
      parsed.endedAt = null;
    } else {
      const endedAt = asFinite(payload.endedAt);
      if (endedAt === null) return null;
      parsed.endedAt = endedAt;
    }
  }
  if (payload.note !== undefined) {
    const note = asNote(payload.note);
    if (note === false || note === undefined) return null;
    parsed.note = note;
  }
  return parsed;
}

function uniqueDates(dates: readonly DateKey[]): DateKey[] {
  return [...new Set(dates)].sort();
}

/* -------------------------------------------------------------------------- */
/* Registration                                                                */
/* -------------------------------------------------------------------------- */

export function registerIpcHandlers(deps: IpcHandlerDeps): void {
  const {
    repo,
    timer,
    prefs,
    windows,
    platform,
    updates,
    dbPath,
    getPendingRecovery,
    resolveRecovery,
    resolveIdle,
    resolveWake,
    platformInfo,
    setLoginItemEnabled,
  } = deps;

  /** Runs `fn`, falling back to a safe value if the database or store misbehaves. */
  function guard<T>(channel: string, fn: () => T, fallback: () => T): T {
    try {
      return fn();
    } catch (error) {
      logFailure(channel, error);
      return fallback();
    }
  }

  function guardMutation<T>(channel: string, fn: () => MutationResult<T>): MutationResult<T> {
    try {
      return fn();
    } catch (error) {
      logFailure(channel, error);
      return { ok: false, code: 'unknown', message: describeError(error) };
    }
  }

  /** Used only when the timer itself cannot be read; the UI still needs a snapshot. */
  function fallbackSnapshot(): TimerSnapshot {
    let targetMinutes = hoursToMinutes(DEFAULT_PREFERENCES.dailyTargetHours);
    try {
      targetMinutes = hoursToMinutes(prefs.get('dailyTargetHours'));
    } catch {
      // Keep the compiled-in default.
    }
    const asOf = Date.now();
    return {
      state: 'IDLE',
      date: todayKey(asOf),
      dayId: null,
      closedWorkedMs: 0,
      closedBreakMs: 0,
      openSegment: null,
      firstStartAt: null,
      lastEndAt: null,
      targetMinutes,
      asOf,
    };
  }

  function defaultTargetMinutes(): number {
    return hoursToMinutes(prefs.get('dailyTargetHours'));
  }

  /**
   * Tell the History windows what to refetch and push a fresh snapshot. `emit()` fans
   * the snapshot out through the main process's subscription, which also refreshes the
   * tray, so this never sends `EVENT.snapshot` itself and duplicates it.
   */
  function announceHistoryChange(dates: readonly DateKey[]): void {
    try {
      windows.broadcast<HistoryInvalidated>(EVENT.historyInvalidated, { dates: [...dates] });
      timer.emit();
    } catch (error) {
      logFailure('history:invalidate', error);
    }
  }

  /* ---------------------------------------------------------------------- */
  /* Timer                                                                   */
  /* ---------------------------------------------------------------------- */

  ipcMain.handle(INVOKE.timerGetSnapshot, (): TimerSnapshot =>
    guard(INVOKE.timerGetSnapshot, () => timer.getSnapshot(), fallbackSnapshot),
  );

  /** Transitions rewrite today's segments, so History is invalidated alongside. */
  function transition(channel: string, run: () => TimerSnapshot): TimerSnapshot {
    return guard(
      channel,
      () => {
        const snapshot = run();
        try {
          windows.broadcast<HistoryInvalidated>(EVENT.historyInvalidated, {
            dates: [snapshot.date],
          });
        } catch (error) {
          logFailure(channel, error);
        }
        return snapshot;
      },
      fallbackSnapshot,
    );
  }

  ipcMain.handle(INVOKE.timerStart, (): TimerSnapshot =>
    transition(INVOKE.timerStart, () => timer.start()),
  );
  ipcMain.handle(INVOKE.timerPause, (): TimerSnapshot =>
    transition(INVOKE.timerPause, () => timer.pause()),
  );
  ipcMain.handle(INVOKE.timerResume, (): TimerSnapshot =>
    transition(INVOKE.timerResume, () => timer.resume()),
  );
  ipcMain.handle(INVOKE.timerEndDay, (): TimerSnapshot =>
    transition(INVOKE.timerEndDay, () => timer.endDay()),
  );

  /* ---------------------------------------------------------------------- */
  /* History — reads                                                         */
  /* ---------------------------------------------------------------------- */

  ipcMain.handle(INVOKE.historyGetDay, (_event, payload: unknown): DayDetail | null => {
    const date = asDateKey(payload);
    if (date === null) return null;
    return guard(
      INVOKE.historyGetDay,
      () => repo.getDayDetail(date, Date.now()),
      () => null,
    );
  });

  ipcMain.handle(INVOKE.historyGetRange, (_event, payload: unknown): RangeSummary => {
    const range = asRange(payload);
    if (range === null) {
      const empty = todayKey();
      return summariseRange({ from: empty, to: empty }, []);
    }
    // A reversed range is not an error, it simply contains nothing.
    if (range.from > range.to) return summariseRange(range, []);
    return guard(
      INVOKE.historyGetRange,
      () => summariseRange(range, repo.getRange(range, Date.now())),
      () => summariseRange(range, []),
    );
  });

  /* ---------------------------------------------------------------------- */
  /* History — segment mutations                                             */
  /* ---------------------------------------------------------------------- */

  /**
   * Every segment already stored on the days a candidate touches.
   *
   * A span that crosses midnight is checked against *both* days, not just the one the
   * edit was addressed to, otherwise its tail could silently land on top of the next
   * morning's work.
   */
  function segmentsOn(dates: readonly DateKey[], now: EpochMs): Segment[] {
    const existing: Segment[] = [];
    for (const date of dates) {
      const detail = repo.getDayDetail(date, now);
      if (detail !== null) existing.push(...detail.segments);
    }
    return existing;
  }

  function createSegment(date: DateKey, write: SegmentWrite): MutationResult<DayDetail> {
    const now = Date.now();
    const pieces = splitAtMidnight(write);
    const dates = uniqueDates([date, ...pieces.map((piece) => piece.date)]);

    const validation = validateSegment(write, segmentsOn(dates, now));
    if (!validation.ok) return validation;

    const detail = repo.transaction(() => {
      const targetMinutes = defaultTargetMinutes();
      // The addressed day is created even if every piece lands elsewhere, so the
      // History window always gets back the day it was editing.
      repo.getOrCreateDay(date, targetMinutes, now);
      for (const piece of pieces) {
        const day = repo.getOrCreateDay(piece.date, targetMinutes, now);
        repo.insertSegment(
          {
            dayId: day.id,
            type: piece.type,
            startedAt: piece.startedAt,
            endedAt: piece.endedAt,
            note: write.note,
          },
          now,
        );
      }
      return repo.getDayDetail(date, now);
    });

    if (detail === null) {
      return { ok: false, code: 'unknown', message: 'The day could not be read back.' };
    }
    announceHistoryChange(dates);
    return { ok: true, value: detail };
  }

  function updateSegment(patch: ParsedUpdate): MutationResult<DayDetail> {
    const now = Date.now();
    const existing = repo.getSegment(patch.id);
    if (existing === null) {
      return { ok: false, code: 'not-found', message: 'That segment no longer exists.' };
    }

    const merged: SegmentWrite = {
      type: patch.type ?? existing.type,
      startedAt: patch.startedAt ?? existing.startedAt,
      endedAt: patch.endedAt !== undefined ? patch.endedAt : existing.endedAt,
      note: patch.note !== undefined ? patch.note : existing.note,
    };

    // At most one segment may be open app-wide; re-opening a closed one must not
    // create a second.
    if (merged.endedAt === null) {
      const open = repo.findOpenSegment();
      if (open !== null && open.id !== existing.id) {
        return {
          ok: false,
          code: 'open-segment-conflict',
          message: 'Another segment is still running.',
        };
      }
    }

    const pieces = splitAtMidnight(merged);
    // The row's original date matters even when the edit moves it, because that day's
    // totals changed too.
    const dates = uniqueDates([
      dateKeyOf(existing.startedAt),
      ...pieces.map((piece) => piece.date),
    ]);

    const validation = validateSegment(merged, segmentsOn(dates, now), existing.id);
    if (!validation.ok) return validation;

    const [head, ...rest] = pieces;
    const detail = repo.transaction(() => {
      const targetMinutes = defaultTargetMinutes();
      const headDay = repo.getOrCreateDay(head.date, targetMinutes, now);

      if (headDay.id === existing.dayId) {
        repo.updateSegmentFields(
          existing.id,
          {
            type: head.type,
            startedAt: head.startedAt,
            endedAt: head.endedAt,
            note: merged.note,
          },
          now,
        );
      } else {
        // `updateSegmentFields` cannot move a row between days, so a segment dragged
        // onto another date is re-filed instead.
        repo.deleteSegment(existing.id);
        repo.insertSegment(
          {
            dayId: headDay.id,
            type: head.type,
            startedAt: head.startedAt,
            endedAt: head.endedAt,
            note: merged.note,
          },
          now,
        );
      }

      for (const piece of rest) {
        const day = repo.getOrCreateDay(piece.date, targetMinutes, now);
        repo.insertSegment(
          {
            dayId: day.id,
            type: piece.type,
            startedAt: piece.startedAt,
            endedAt: piece.endedAt,
            note: merged.note,
          },
          now,
        );
      }

      return repo.getDayDetail(head.date, now);
    });

    if (detail === null) {
      return { ok: false, code: 'unknown', message: 'The day could not be read back.' };
    }
    announceHistoryChange(dates);
    return { ok: true, value: detail };
  }

  function deleteSegment(id: number): MutationResult<DayDetail | null> {
    const now = Date.now();
    const existing = repo.getSegment(id);
    if (existing === null) {
      return { ok: false, code: 'not-found', message: 'That segment no longer exists.' };
    }
    if (existing.endedAt === null) {
      return {
        ok: false,
        code: 'open-segment-conflict',
        message: 'Stop the timer before deleting the segment it is still writing to.',
      };
    }

    // Stored segments always start inside the day they are filed under — the splitter
    // guarantees it — so the start instant identifies the day without a second lookup.
    const date = dateKeyOf(existing.startedAt);
    const removed = repo.transaction(() => repo.deleteSegment(id));
    if (!removed) {
      return { ok: false, code: 'not-found', message: 'That segment no longer exists.' };
    }

    announceHistoryChange([date]);
    return { ok: true, value: repo.getDayDetail(date, now) };
  }

  ipcMain.handle(
    INVOKE.historyCreateSegment,
    (_event, payload: unknown): MutationResult<DayDetail> => {
      const request = parseCreate(payload);
      if (request === null) return invalidPayload('That segment could not be read.');
      return guardMutation(INVOKE.historyCreateSegment, () =>
        createSegment(request.date, request.write),
      );
    },
  );

  ipcMain.handle(
    INVOKE.historyUpdateSegment,
    (_event, payload: unknown): MutationResult<DayDetail> => {
      const patch = parseUpdate(payload);
      if (patch === null) return invalidPayload('That edit could not be read.');
      return guardMutation(INVOKE.historyUpdateSegment, () => updateSegment(patch));
    },
  );

  ipcMain.handle(
    INVOKE.historyDeleteSegment,
    (_event, payload: unknown): MutationResult<DayDetail | null> => {
      const id = asId(payload);
      if (id === null) return invalidPayload('That segment could not be identified.');
      return guardMutation(INVOKE.historyDeleteSegment, () => deleteSegment(id));
    },
  );

  /* ---------------------------------------------------------------------- */
  /* History — export                                                        */
  /* ---------------------------------------------------------------------- */

  ipcMain.handle(
    INVOKE.historyExport,
    async (event, payload: unknown): Promise<FileWriteResult> => {
      if (!isRecord(payload)) {
        return { ok: false, cancelled: false, message: 'That export request could not be read.' };
      }
      const format = pickLiteral(payload.format, EXPORT_FORMATS);
      const range = asRange(payload.range);
      if (format === null || range === null || range.from > range.to) {
        return { ok: false, cancelled: false, message: 'That export request could not be read.' };
      }

      try {
        const days = repo.getRange(range, Date.now());
        const content = format === 'csv' ? buildCsv(days) : buildJson(days, range);

        const options: SaveDialogOptions = {
          title: 'Export Dayly data',
          defaultPath: `dayly-${range.from}_to_${range.to}.${format}`,
          filters: [
            format === 'csv'
              ? { name: 'CSV', extensions: ['csv'] }
              : { name: 'JSON', extensions: ['json'] },
          ],
        };

        const parent = BrowserWindow.fromWebContents(event.sender);
        const chosen =
          parent === null
            ? await dialog.showSaveDialog(options)
            : await dialog.showSaveDialog(parent, options);
        if (chosen.canceled || chosen.filePath.length === 0) return { ok: false, cancelled: true };

        await writeFile(chosen.filePath, content, 'utf8');
        return { ok: true, path: chosen.filePath };
      } catch (error) {
        logFailure(INVOKE.historyExport, error);
        return { ok: false, cancelled: false, message: describeError(error) };
      }
    },
  );

  /* ---------------------------------------------------------------------- */
  /* Preferences                                                             */
  /* ---------------------------------------------------------------------- */

  /**
   * Writes one preference, rejecting unknown keys and values of the wrong type. The
   * store still clamps ranges; this only guarantees it is handed the right shape.
   *
   * `null` means the request was refused and nothing was written. It is async only
   * because `launchAtLogin` has work to do outside the store before it may be stored.
   */
  async function writePreference(key: string, value: unknown): Promise<Preferences | null> {
    switch (key) {
      case 'launchAtLogin': {
        if (typeof value !== 'boolean') return null;
        // The OS goes first and is awaited. A refused registration — an unwritable
        // autostart directory, a denied `SMAppService` — used to be applied after the
        // reply had already been sent, so the store kept a `true` describing a login
        // item that does not exist and the user was told it had saved. Letting this
        // reject leaves the preference untouched, which is the honest answer.
        await setLoginItemEnabled(value);
        return prefs.set(key, value);
      }

      case 'showMiniWindow':
      case 'idleDetectionEnabled':
      case 'autoPauseOnSleep':
      case 'autoPauseOnLock':
      case 'reminderEnabled':
      case 'trayFallbackNoticeShown':
      case 'updateCheckEnabled':
        return typeof value === 'boolean' ? prefs.set(key, value) : null;

      case 'idleThresholdMinutes':
      case 'dailyTargetHours':
      case 'reminderHour':
      case 'reminderMinute': {
        const numeric = asFinite(value);
        return numeric === null ? null : prefs.set(key, numeric);
      }

      case 'theme': {
        const theme = pickLiteral(value, THEMES);
        return theme === null ? null : prefs.set(key, theme);
      }

      case 'weekStartsOn': {
        const weekStart = pickLiteral(value, WEEK_STARTS);
        return weekStart === null ? null : prefs.set(key, weekStart);
      }

      case 'miniWindowPositions': {
        const positions = asMiniWindowPositions(value);
        return positions === null ? null : prefs.set(key, positions);
      }

      default:
        return null;
    }
  }

  ipcMain.handle(INVOKE.prefsGetAll, (): Preferences =>
    guard(
      INVOKE.prefsGetAll,
      () => prefs.getAll(),
      // Deliberately asymmetric with `prefs:set` below, and the asymmetry is the point.
      // A window handed nothing cannot render at all, so a failed *read* falls back to
      // the compiled-in defaults and the app stays usable. A failed *write* must not:
      // defaults returned from a write are indistinguishable from a saved value, so the
      // window would confirm settings the user never chose and quietly drop the ones
      // they did. A read that lies is a wrong screen; a write that lies is lost data.
      () => DEFAULT_PREFERENCES,
    ),
  );

  /**
   * The one channel in this file that is allowed to reject.
   *
   * There is no `MutationResult` here to carry a failure, and every value this could
   * fall back to — the defaults, or the preferences as they still stand — is a set of
   * preferences the renderer would assign to state and report as saved. So a write that
   * did not happen throws, which is the only signal the contract has left. The UI is
   * already waiting for it: `usePrefs.setPref` assigns state on success only, so the
   * control snaps back to its real value, and `SettingsApp.write` flashes "Could not
   * save" instead of "Saved".
   */
  ipcMain.handle(INVOKE.prefsSet, async (_event, payload: unknown): Promise<Preferences> => {
    try {
      if (!isRecord(payload) || typeof payload.key !== 'string') {
        throw new Error('A preference write must name the preference to write.');
      }
      const next = await writePreference(payload.key, payload.value);
      if (next === null) {
        // An unknown key or a mistyped value left the stored preferences untouched, so
        // saying so is the only truthful reply.
        throw new Error(`Could not save "${payload.key}": unknown preference, or wrong type.`);
      }
      return next;
    } catch (error) {
      // Logged as well as rethrown: the renderer only ever sees an opaque Error, so the
      // reason for the refusal would otherwise exist nowhere.
      logFailure(INVOKE.prefsSet, error);
      throw error;
    }
  });

  ipcMain.handle(INVOKE.prefsReset, (): Preferences =>
    guard(
      INVOKE.prefsReset,
      () => prefs.reset(),
      () => DEFAULT_PREFERENCES,
    ),
  );

  /* ---------------------------------------------------------------------- */
  /* Windows                                                                 */
  /* ---------------------------------------------------------------------- */

  ipcMain.handle(INVOKE.windowsOpen, (_event, payload: unknown): void => {
    const kind = pickLiteral(payload, WINDOW_KINDS);
    if (kind === null) return;
    guard(
      INVOKE.windowsOpen,
      () => {
        windows.open(kind);
      },
      () => undefined,
    );
  });

  ipcMain.handle(INVOKE.windowsClose, (_event, payload: unknown): void => {
    const kind = pickLiteral(payload, WINDOW_KINDS);
    if (kind === null) return;
    guard(
      INVOKE.windowsClose,
      () => {
        windows.close(kind);
      },
      () => undefined,
    );
  });

  ipcMain.handle(INVOKE.windowsMiniMoved, (_event, payload: unknown): void => {
    if (!isRecord(payload) || asFinite(payload.x) === null || asFinite(payload.y) === null) return;
    // The reported coordinates only say *that* the window moved: the manager reads the
    // authoritative bounds itself, so a renderer cannot teleport the window.
    guard(
      INVOKE.windowsMiniMoved,
      () => {
        windows.rememberMiniPosition();
      },
      () => undefined,
    );
  });

  /* ---------------------------------------------------------------------- */
  /* System                                                                  */
  /* ---------------------------------------------------------------------- */

  ipcMain.handle(INVOKE.systemGetPlatformInfo, (): PlatformInfo => platformInfo());

  ipcMain.handle(INVOKE.systemGetDataPath, (): string => dirname(dbPath));

  ipcMain.handle(INVOKE.systemRevealDataFolder, async (): Promise<void> => {
    try {
      await platform.revealInFileManager(dbPath);
    } catch (error) {
      logFailure(INVOKE.systemRevealDataFolder, error);
    }
  });

  ipcMain.handle(INVOKE.systemBackupDatabase, async (event): Promise<FileWriteResult> => {
    try {
      return await backupDatabase(dbPath, BrowserWindow.fromWebContents(event.sender));
    } catch (error) {
      logFailure(INVOKE.systemBackupDatabase, error);
      return { ok: false, cancelled: false, message: describeError(error) };
    }
  });

  ipcMain.handle(INVOKE.systemQuit, (): void => {
    // The main entry raises its `quitting` flag from `before-quit`, which `app.quit()`
    // fires before any window receives a close event, so the windows really close.
    app.quit();
  });

  /* ---------------------------------------------------------------------- */
  /* Updates                                                                 */
  /* ---------------------------------------------------------------------- */

  /**
   * None of these channels carries a payload — the state they act on lives entirely in
   * `UpdateService` — so there is nothing to narrow and any argument a renderer invents
   * is ignored rather than trusted. What still has to be guaranteed is the other half of
   * the trust boundary: nothing throws across the bridge. A failed check is a *status*,
   * not a rejection, so the UI always has something it can render.
   */
  function updateFallback(message: string): UpdateStatus {
    return { kind: 'error', message };
  }

  ipcMain.handle(INVOKE.updatesGetInfo, (): UpdateInfo =>
    guard(INVOKE.updatesGetInfo, () => updates.getInfo(), () => ({
      currentVersion: app.getVersion(),
      canAutoUpdate: false,
      releasesUrl: platform.releasesUrl,
    })),
  );

  ipcMain.handle(INVOKE.updatesGetStatus, (): UpdateStatus =>
    guard(INVOKE.updatesGetStatus, () => updates.getStatus(), () => ({ kind: 'idle' })),
  );

  ipcMain.handle(INVOKE.updatesCheckNow, async (): Promise<UpdateStatus> => {
    try {
      return await updates.checkNow();
    } catch (error) {
      logFailure(INVOKE.updatesCheckNow, error);
      return updateFallback(describeError(error));
    }
  });

  ipcMain.handle(INVOKE.updatesDownload, async (): Promise<UpdateStatus> => {
    try {
      return await updates.download();
    } catch (error) {
      logFailure(INVOKE.updatesDownload, error);
      return updateFallback(describeError(error));
    }
  });

  ipcMain.handle(INVOKE.updatesInstallNow, (): void => {
    // Quits the app, so it is the last thing this process does. `UpdateService` ignores
    // the call unless an update is actually staged.
    guard(
      INVOKE.updatesInstallNow,
      () => {
        updates.installNow();
      },
      () => undefined,
    );
  });

  ipcMain.handle(INVOKE.updatesOpenReleases, async (): Promise<void> => {
    try {
      await updates.openReleases();
    } catch (error) {
      logFailure(INVOKE.updatesOpenReleases, error);
    }
  });

  /* ---------------------------------------------------------------------- */
  /* Prompts                                                                 */
  /* ---------------------------------------------------------------------- */

  ipcMain.handle(INVOKE.promptsGetRecovery, (): PendingRecovery | null =>
    guard(INVOKE.promptsGetRecovery, getPendingRecovery, () => null),
  );

  ipcMain.handle(INVOKE.promptsResolveRecovery, (_event, payload: unknown): TimerSnapshot => {
    const choice = pickLiteral(payload, RECOVERY_CHOICES);
    if (choice === null) {
      return guard(INVOKE.promptsResolveRecovery, () => timer.getSnapshot(), fallbackSnapshot);
    }
    return guard(INVOKE.promptsResolveRecovery, () => resolveRecovery(choice), fallbackSnapshot);
  });

  ipcMain.handle(INVOKE.promptsResolveIdle, (_event, payload: unknown): TimerSnapshot => {
    const promptId = isRecord(payload) && typeof payload.promptId === 'string' ? payload.promptId : null;
    const choice = isRecord(payload) ? pickLiteral(payload.choice, IDLE_CHOICES) : null;
    if (promptId === null || choice === null) {
      return guard(INVOKE.promptsResolveIdle, () => timer.getSnapshot(), fallbackSnapshot);
    }
    return guard(INVOKE.promptsResolveIdle, () => resolveIdle(promptId, choice), fallbackSnapshot);
  });

  ipcMain.handle(INVOKE.promptsResolveWake, (_event, payload: unknown): TimerSnapshot => {
    const promptId = isRecord(payload) && typeof payload.promptId === 'string' ? payload.promptId : null;
    const choice = isRecord(payload) ? pickLiteral(payload.choice, WAKE_CHOICES) : null;
    if (promptId === null || choice === null) {
      return guard(INVOKE.promptsResolveWake, () => timer.getSnapshot(), fallbackSnapshot);
    }
    return guard(INVOKE.promptsResolveWake, () => resolveWake(promptId, choice), fallbackSnapshot);
  });

  ipcMain.handle(INVOKE.promptsDismissNotice, (_event, payload: unknown): void => {
    // Notices are fire-and-forget: dismissal is renderer state, and the flag that stops
    // a notice from reappearing (`trayFallbackNoticeShown`) is written when it is sent.
    // The id is still validated so nothing untyped reaches the bridge unchallenged.
    if (typeof payload !== 'string' || payload.length === 0) {
      logFailure(INVOKE.promptsDismissNotice, new Error('A notice id must be a non-empty string.'));
    }
  });
}
