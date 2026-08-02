/**
 * The Settings window (560x720, framed — no drag regions needed).
 *
 * There is no Save button: every control writes through on change and the main
 * process, which clamps and persists the value, answers with the stored result. That
 * makes the header's "Saved" line the only confirmation the user gets, so a write
 * that *fails* has to be reported in the same place rather than silently reverting.
 *
 * `miniWindowPositions` and `trayFallbackNoticeShown` are deliberately absent: they
 * are bookkeeping the app writes for itself, not choices anyone makes.
 */

import { useCallback, useEffect, useId, useRef, useState } from 'react';
import type { ReactNode } from 'react';

import type { Preferences } from '@shared/types';

import { Button } from '@renderer/components/Button';
import { NumberField } from '@renderer/components/NumberField';
import { Toggle } from '@renderer/components/Toggle';
import { UpdateNotice } from '@renderer/components/UpdateNotice';
import { usePlatformInfo } from '@renderer/hooks/usePlatformInfo';
import { usePrefs } from '@renderer/hooks/usePrefs';
import { useUpdates } from '@renderer/hooks/useUpdates';
import { api, cn } from '@renderer/lib/api';

import { SettingsSection } from './SettingsSection';

/** How long the "Saved" line stays up before fading out. */
const SAVED_VISIBLE_MS = 1_800;

type SaveStatus = 'idle' | 'saved' | 'error';

type BackupState =
  | { kind: 'idle' }
  | { kind: 'busy' }
  | { kind: 'done'; path: string }
  | { kind: 'error'; message: string };

interface SegmentedOption<T extends string | number> {
  value: T;
  label: string;
}

const THEME_OPTIONS: readonly SegmentedOption<Preferences['theme']>[] = [
  { value: 'system', label: 'System' },
  { value: 'light', label: 'Light' },
  { value: 'dark', label: 'Dark' },
];

const WEEK_START_OPTIONS: readonly SegmentedOption<Preferences['weekStartsOn']>[] = [
  { value: 0, label: 'Sunday' },
  { value: 1, label: 'Monday' },
];

function pad2(value: number): string {
  return value < 10 ? `0${value}` : String(value);
}

/**
 * Read an `<input type="time">` value. The field hands over `''` while the user is
 * still filling it in, and the two halves of the reminder are separate preferences,
 * so anything incomplete must resolve to `null` rather than to a half-written time.
 */
function parseTimeInput(value: string): { hour: number; minute: number } | null {
  const parts = value.split(':');
  if (parts.length < 2) return null;
  const hour = Number(parts[0]);
  const minute = Number(parts[1]);
  if (!Number.isInteger(hour) || !Number.isInteger(minute)) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return { hour, minute };
}

export function SettingsApp() {
  const { prefs, setPref } = usePrefs();
  const platform = usePlatformInfo();
  const updates = useUpdates();
  const reminderTimeId = useId();

  const [status, setStatus] = useState<SaveStatus>('idle');
  const [dataPath, setDataPath] = useState<string | null>(null);
  const [backup, setBackup] = useState<BackupState>({ kind: 'idle' });
  const flashTimer = useRef<number | null>(null);

  useEffect(() => {
    let active = true;
    void api.system
      .getDataPath()
      .then((path) => {
        if (active) setDataPath(path);
      })
      .catch(() => undefined);
    return () => {
      active = false;
    };
  }, []);

  useEffect(
    () => () => {
      if (flashTimer.current !== null) window.clearTimeout(flashTimer.current);
    },
    [],
  );

  const flash = useCallback((next: Exclude<SaveStatus, 'idle'>): void => {
    setStatus(next);
    // Rapid edits restart the window rather than stacking timers, so the line stays
    // up for the whole burst instead of blinking once per keystroke.
    if (flashTimer.current !== null) window.clearTimeout(flashTimer.current);
    flashTimer.current = window.setTimeout(() => {
      flashTimer.current = null;
      setStatus('idle');
    }, SAVED_VISIBLE_MS);
  }, []);

  const write = useCallback(
    <K extends keyof Preferences>(key: K, value: Preferences[K]): void => {
      void setPref(key, value).then(
        () => flash('saved'),
        () => flash('error'),
      );
    },
    [setPref, flash],
  );

  /** The reminder is one field on screen but two preferences underneath; they are
   *  written in sequence so the second write sees the first one's store. */
  const writeReminderTime = useCallback(
    (raw: string): void => {
      const parsed = parseTimeInput(raw);
      if (parsed === null) return;
      const apply = async (): Promise<void> => {
        await setPref('reminderHour', parsed.hour);
        await setPref('reminderMinute', parsed.minute);
      };
      void apply().then(
        () => flash('saved'),
        () => flash('error'),
      );
    },
    [setPref, flash],
  );

  // Revealing is a fire-and-forget shell call; a failure shows up as "nothing opened",
  // and the path is on screen right above the button either way.
  const reveal = useCallback((): void => {
    void api.system.revealDataFolder().catch(() => undefined);
  }, []);

  const runBackup = useCallback((): void => {
    setBackup({ kind: 'busy' });
    void api.system.backupDatabase().then(
      (result) => {
        if (result.ok) {
          setBackup({ kind: 'done', path: result.path });
        } else if (result.cancelled) {
          // Dismissing the save dialog is a normal outcome, not something to report.
          setBackup({ kind: 'idle' });
        } else {
          setBackup({ kind: 'error', message: result.message });
        }
      },
      () => setBackup({ kind: 'error', message: 'The backup could not be started.' }),
    );
  }, []);

  // `null` means the probe has not answered yet; assume the ordinary case until it does.
  const trayFallbackActive = platform?.trayFallbackActive === true;
  const menuBarShowsTime = platform?.supportsTrayTitle === true;
  // Assume the capability until the probe answers, so the toggle is not disabled for a
  // frame on the platforms that do have it. Claiming absence on an unanswered question
  // is its own kind of lying.
  const supportsLockDetection = platform === null || platform.supportsLockDetection;

  const miniWindowDescription = trayFallbackActive
    ? 'This desktop has no system tray, so the mini window is Dayly’s only always-visible surface. It cannot be turned off here.'
    : menuBarShowsTime
      ? 'A small always-on-top clock. The menu bar already shows your running time, so this is optional.'
      : 'A small always-on-top clock you can park anywhere on screen.';

  // Until `getInfo` answers, the row shows the label without a number rather than a
  // guessed one — the version is the whole point of the line.
  const versionLabel = updates.info === null ? 'Version' : `Version ${updates.info.currentVersion}`;

  // `null` means `getInfo` has not answered yet; assume the ordinary case until it does,
  // the same way the platform probe above does. Claiming a build is incapable on the
  // strength of an unanswered question would be its own kind of lying.
  const canAutoUpdate = updates.info === null || updates.info.canAutoUpdate;

  // The gate in UpdateService is all-or-nothing: where a self-update cannot work there is
  // also no feed to ask, so the check is never scheduled and this toggle would be a
  // switch wired to nothing. It is disabled rather than left to look meaningful.
  const updateCheckDescription = canAutoUpdate
    ? 'Dayly’s only network request. Nothing is downloaded without asking.'
    : 'This build has no update feed, so there is nothing to check on a schedule. Dayly makes no network request either way.';

  // Nothing ever checks on such a build, so the notification this line used to promise
  // was never coming; the Releases page is the only place a new version shows up.
  const versionDescription = canAutoUpdate
    ? undefined
    : 'This build can’t install updates or check for them, so Dayly won’t tell you when a new version exists — look on the Releases page.';

  // The section header makes the same claim as the toggle and has to fall the same way:
  // a build with no feed performs no version check, so promising one here would put the
  // lie back two lines above the place it was just removed from.
  const updatesSectionDescription = canAutoUpdate
    ? 'A version check against the project’s public releases page. No account, no telemetry, no payload.'
    : 'This build has no update feed, so Dayly never checks. New versions live on the project’s public releases page.';

  return (
    <div className="flex h-screen w-screen flex-col overflow-hidden bg-surface text-fg antialiased">
      <header className="flex shrink-0 items-center justify-between gap-3 border-b border-border px-6 py-3">
        <h1 className="text-sm font-semibold">Settings</h1>
        <SavedNote status={status} />
      </header>

      <main className="min-h-0 flex-1 overflow-y-auto">
        {prefs === null ? (
          <p className="px-6 py-8 text-sm text-fg-faint">Loading your preferences…</p>
        ) : (
          <div className="flex flex-col gap-6 px-5 py-5">
            <SettingsSection title="General" description="How Dayly starts up and how it looks.">
              <Toggle
                checked={prefs.launchAtLogin}
                onChange={(next) => write('launchAtLogin', next)}
                label="Launch at login"
                description="Starts Dayly in the background when you sign in."
              />

              <Toggle
                checked={prefs.showMiniWindow}
                onChange={(next) => write('showMiniWindow', next)}
                label="Show the mini window"
                description={miniWindowDescription}
                disabled={trayFallbackActive}
              />

              <SettingsRow
                label="Appearance"
                description="System follows your desktop’s light or dark setting."
                control={
                  <SegmentedControl
                    label="Appearance"
                    value={prefs.theme}
                    options={THEME_OPTIONS}
                    onChange={(next) => write('theme', next)}
                  />
                }
              />

              <SettingsRow
                label="Week starts on"
                description="Used by the week totals in History."
                control={
                  <SegmentedControl
                    label="Week starts on"
                    value={prefs.weekStartsOn}
                    options={WEEK_START_OPTIONS}
                    onChange={(next) => write('weekStartsOn', next)}
                  />
                }
              />
            </SettingsSection>

            <SettingsSection
              title="Tracking"
              description="Your target, and when Dayly should question the time it is counting."
            >
              <NumberField
                value={prefs.dailyTargetHours}
                onChange={(next) => write('dailyTargetHours', next)}
                label="Daily target"
                description="Drives the progress bar and the target-met markers in History."
                min={0}
                max={24}
                step={0.5}
                suffix="hours"
              />

              <Toggle
                checked={prefs.idleDetectionEnabled}
                onChange={(next) => write('idleDetectionEnabled', next)}
                label="Detect when you step away"
                description="While the timer runs, Dayly watches how long the machine has been untouched and asks whether to keep the time."
              />

              <NumberField
                value={prefs.idleThresholdMinutes}
                onChange={(next) => write('idleThresholdMinutes', next)}
                label="Ask after"
                description={
                  prefs.idleDetectionEnabled
                    ? 'How long the machine must sit untouched before Dayly asks.'
                    : 'Turn on “Detect when you step away” to change this.'
                }
                min={1}
                max={240}
                suffix="minutes"
                disabled={!prefs.idleDetectionEnabled}
              />

              <Toggle
                checked={prefs.autoPauseOnSleep}
                onChange={(next) => write('autoPauseOnSleep', next)}
                label="Pause when the computer sleeps"
                description="The gap is held until you are back, then you choose whether it was a break."
              />

              <Toggle
                checked={prefs.autoPauseOnLock && supportsLockDetection}
                onChange={(next) => write('autoPauseOnLock', next)}
                label="Pause when the screen locks"
                description={
                  supportsLockDetection
                    ? 'Off by default — a lock during a call or a screensaver is not always a break.'
                    : 'Not available on Linux: the desktop never tells Dayly the screen locked, so this could only ever look like it was working. Sleep is still detected.'
                }
                disabled={!supportsLockDetection}
              />
            </SettingsSection>

            <SettingsSection
              title="Reminders"
              description="One nudge a day, and only while the timer is still running."
            >
              <Toggle
                checked={prefs.reminderEnabled}
                onChange={(next) => write('reminderEnabled', next)}
                label="Remind me to stop"
                description="Fires at most once per day, at the time below."
              />

              <SettingsRow
                label="Reminder time"
                htmlFor={reminderTimeId}
                description={
                  prefs.reminderEnabled
                    ? 'Local time, on a 24-hour clock or your locale’s equivalent.'
                    : 'Turn reminders on to choose a time.'
                }
                control={
                  <input
                    id={reminderTimeId}
                    type="time"
                    value={`${pad2(prefs.reminderHour)}:${pad2(prefs.reminderMinute)}`}
                    disabled={!prefs.reminderEnabled}
                    onChange={(event) => writeReminderTime(event.target.value)}
                    className={cn(
                      'h-9 rounded-lg border border-border bg-raised px-2.5 text-sm tabular-nums',
                      'text-fg outline-none transition-colors focus:border-accent',
                      !prefs.reminderEnabled && 'cursor-not-allowed opacity-45',
                    )}
                  />
                }
              />
            </SettingsSection>

            <SettingsSection
              title="Data"
              description="Everything Dayly records stays on this machine. Nothing is ever uploaded."
            >
              <div className="px-2 py-2">
                <span className="block text-sm font-medium text-fg">Data folder</span>
                <p className="mt-0.5 text-xs leading-relaxed text-fg-faint">
                  Your database and preferences live here.
                </p>
                <p
                  // The path can be far wider than the window; truncating keeps the
                  // layout, and the tooltip plus selectable text keep it usable.
                  title={dataPath ?? undefined}
                  className="mt-2 truncate rounded-lg border border-border bg-sunken px-2.5 py-1.5 font-mono text-xs text-fg-muted select-text"
                >
                  {dataPath ?? 'Locating…'}
                </p>
              </div>

              <div className="px-2 py-2">
                <div className="flex flex-wrap items-center gap-2">
                  <Button onClick={reveal}>Reveal in file manager</Button>
                  <Button onClick={runBackup} disabled={backup.kind === 'busy'}>
                    {backup.kind === 'busy' ? 'Backing up…' : 'Back up database…'}
                  </Button>
                </div>

                {backup.kind === 'done' && (
                  <p className="mt-2 text-xs leading-relaxed text-work">
                    Backed up to{' '}
                    <span className="font-mono break-all select-text">{backup.path}</span>
                  </p>
                )}
                {backup.kind === 'error' && (
                  <p className="mt-2 text-xs leading-relaxed text-danger">{backup.message}</p>
                )}
              </div>
            </SettingsSection>

            <SettingsSection title="Updates" description={updatesSectionDescription}>
              <Toggle
                checked={prefs.updateCheckEnabled}
                onChange={(next) => write('updateCheckEnabled', next)}
                label="Check for updates automatically"
                description={updateCheckDescription}
                disabled={!canAutoUpdate}
              />

              <SettingsRow
                label={versionLabel}
                description={versionDescription}
                control={
                  <UpdateNotice
                    compact
                    status={updates.status}
                    info={updates.info}
                    onCheck={() => void updates.checkNow()}
                    onDownload={() => void updates.download()}
                    onInstall={() => void updates.installNow()}
                    onOpenReleases={() => void updates.openReleases()}
                  />
                }
              />
            </SettingsSection>
          </div>
        )}
      </main>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Local pieces                                                                */
/* -------------------------------------------------------------------------- */

interface SettingsRowProps {
  label: string;
  description?: string;
  /** Set when the control is a single focusable input, so the label targets it. */
  htmlFor?: string;
  control: ReactNode;
}

function SettingsRow({ label, description, htmlFor, control }: SettingsRowProps) {
  return (
    <div className="flex items-center justify-between gap-4 px-2 py-2">
      <div className="min-w-0">
        {htmlFor === undefined ? (
          <span className="block text-sm font-medium text-fg">{label}</span>
        ) : (
          <label htmlFor={htmlFor} className="block text-sm font-medium text-fg">
            {label}
          </label>
        )}
        {description === undefined ? null : (
          <p className="mt-0.5 text-xs leading-relaxed text-fg-faint">{description}</p>
        )}
      </div>
      <div className="shrink-0">{control}</div>
    </div>
  );
}

interface SegmentedControlProps<T extends string | number> {
  value: T;
  options: readonly SegmentedOption<T>[];
  onChange: (next: T) => void;
  /** Names the group for assistive tech; the visible label sits in the row. */
  label: string;
}

function SegmentedControl<T extends string | number>({
  value,
  options,
  onChange,
  label,
}: SegmentedControlProps<T>) {
  return (
    <div
      role="radiogroup"
      aria-label={label}
      className="inline-flex items-center gap-0.5 rounded-lg border border-border bg-sunken p-0.5"
    >
      {options.map((option) => {
        const selected = option.value === value;
        return (
          <button
            key={String(option.value)}
            type="button"
            role="radio"
            aria-checked={selected}
            // Re-picking the current option would write a preference that did not
            // change, and flash a "Saved" the user did nothing to earn.
            onClick={() => {
              if (!selected) onChange(option.value);
            }}
            className={cn(
              'h-7 rounded-md px-2.5 text-xs font-medium transition-colors duration-150',
              'focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent',
              selected ? 'bg-raised text-fg shadow-sm' : 'text-fg-muted hover:text-fg',
            )}
          >
            {option.label}
          </button>
        );
      })}
    </div>
  );
}

function SavedNote({ status }: { status: SaveStatus }) {
  const failed = status === 'error';
  return (
    <p
      aria-live="polite"
      className={cn(
        'flex items-center gap-1.5 text-xs transition-opacity duration-500',
        status === 'idle' ? 'opacity-0' : 'opacity-100',
        failed ? 'text-danger' : 'text-fg-faint',
      )}
    >
      {failed ? null : <CheckIcon />}
      {failed ? 'Could not save' : 'Saved'}
    </p>
  );
}

function CheckIcon() {
  return (
    <svg
      viewBox="0 0 16 16"
      aria-hidden
      className="size-3.5"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.75"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M3.5 8.5 6.5 11.5 12.5 5" />
    </svg>
  );
}
