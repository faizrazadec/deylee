/**
 * The liveness heartbeat behind crash recovery.
 *
 * While a segment is open the main process stamps the current instant into
 * `app_state` every 30s. If the app dies without closing the segment, that stamp is
 * the last moment we know the machine was genuinely in use, and `@domain/recovery`
 * turns it into the choice the user is offered on the next launch.
 *
 * The write must never take the app down with it: a locked or read-only database at
 * this point would only cost recovery precision, which is far cheaper than a crash.
 */

import { APP_STATE_HEARTBEAT } from '@main/db/repository';
import type { Repository } from '@main/db/repository';

const DEFAULT_INTERVAL_MS = 30_000;

export class HeartbeatService {
  private readonly repo: Repository;
  private readonly intervalMs: number;
  private handle: ReturnType<typeof setInterval> | null = null;

  constructor(repo: Repository, intervalMs: number = DEFAULT_INTERVAL_MS) {
    this.repo = repo;
    this.intervalMs = intervalMs;
  }

  start(): void {
    if (this.handle !== null) return;
    // Stamp immediately: a crash inside the first interval must still be recoverable
    // to something later than the segment's own start.
    this.writeNow();
    this.handle = setInterval(() => {
      this.writeNow();
    }, this.intervalMs);
  }

  stop(): void {
    if (this.handle === null) return;
    clearInterval(this.handle);
    this.handle = null;
  }

  writeNow(): void {
    try {
      this.repo.setAppState(APP_STATE_HEARTBEAT, String(Date.now()));
    } catch (error) {
      console.error('[heartbeat] failed to write heartbeat', error);
    }
  }
}
