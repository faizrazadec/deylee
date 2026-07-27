/**
 * Today's segment list.
 *
 * The snapshot carries only the *open* segment, so the closed ones are read back
 * through `history.getDay`. The panel decides when that data is stale and hands down
 * an opaque `revision`, which keeps the refetch trigger in one place instead of
 * having this list run subscriptions of its own.
 *
 * Read-only here: adding, editing and deleting segments belong to the History window.
 */

import { useEffect, useRef, useState } from 'react';

import type { DateKey, Segment } from '@shared/types';

import { EmptyState } from '@renderer/components/EmptyState';
import { SegmentRow } from '@renderer/components/SegmentRow';
import { api } from '@renderer/lib/api';

export interface TodaySegmentsProps {
  date: DateKey;
  /** Render tick, so an open segment's duration keeps climbing in its row. */
  now: number;
  /** Opaque token: whenever it changes, the day is read again. */
  revision: string;
}

export function TodaySegments({ date, now, revision }: TodaySegmentsProps) {
  const [segments, setSegments] = useState<readonly Segment[]>([]);
  const [loaded, setLoaded] = useState(false);
  const listRef = useRef<HTMLUListElement>(null);

  useEffect(() => {
    let active = true;

    void api.history
      .getDay(date)
      .then((detail) => {
        if (!active) return;
        setSegments(detail === null ? [] : detail.segments);
        setLoaded(true);
      })
      // A failed read is not worth a dialog in a 340px panel; the next revision retries.
      .catch(() => {
        if (active) setLoaded(true);
      });

    return () => {
      active = false;
    };
  }, [date, revision]);

  // The list is chronological, so the segment that is running sits at the bottom.
  // Pin the scroll there as segments accumulate, so "now" is what you see on open.
  useEffect(() => {
    const list = listRef.current;
    if (list !== null) list.scrollTop = list.scrollHeight;
  }, [segments.length]);

  if (!loaded) {
    // Blank, not a spinner: this is a local SQLite read and lands within a frame or two.
    return <div className="min-h-0 flex-1" />;
  }

  if (segments.length === 0) {
    return (
      <div className="min-h-0 flex-1 overflow-y-auto">
        <EmptyState title="Nothing tracked yet" description="Press Start to open the day." />
      </div>
    );
  }

  return (
    <ul ref={listRef} className="min-h-0 flex-1 space-y-1 overflow-y-auto">
      {segments.map((segment) => (
        <li key={segment.id}>
          <SegmentRow segment={segment} now={now} />
        </li>
      ))}
    </ul>
  );
}
