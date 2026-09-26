-- Witnessed time: keep the evidence, not every beat of it, for ever.
--
-- A running timer beats every thirty seconds, so witness_beats gains ~1200 rows per
-- user per working day and nothing ever removed one: a year of 100 users was 30M rows
-- and 4.6 GB, 98% of the database, and the all-users report reread every one of them.
-- None of that detail is needed for long. What the report counts is a sum of gaps, and
-- a sum survives being added up early.
--
-- So beats age through three tiers, by UTC day:
--
--   under 30 days   the raw beats, as recorded
--   30 to 90 days   spans: one row per unbroken run of beats (~5 a day), which still
--                   says when the timer was heard, so one segment can be checked
--   over 90 days    one total per user per day
--
-- The report's numbers do not change. Each beat vouches for the gap back to the one
-- before it, at most 45 seconds, and that gap belongs to the later beat's day. A span
-- stores exactly the sum of its beats' gaps, a day the sum of its spans, and each keeps
-- its last beat so the next beat after it still has something to measure back to.
--
-- Still append-only to the API: deylee_api holds no grant on any of the three tables or
-- on the compaction. The nightly job runs it as the owner (server/scripts/nightly-db.sh).

create table if not exists public.witness_spans (
  user_id      uuid   not null references public.app_users(id) on delete cascade,
  beat_date    text   not null,
  started_at   bigint not null,  -- first beat, server clock
  ended_at     bigint not null,  -- last beat
  witnessed_ms bigint not null,
  primary key (user_id, started_at)
);

create index if not exists witness_spans_by_user_day
  on public.witness_spans (user_id, beat_date);

create table if not exists public.witness_days (
  user_id      uuid   not null references public.app_users(id) on delete cascade,
  beat_date    text   not null,
  witnessed_ms bigint not null,
  last_beat_at bigint not null,
  primary key (user_id, beat_date)
);

alter table public.witness_spans enable row level security;
alter table public.witness_spans force row level security;
alter table public.witness_days enable row level security;
alter table public.witness_days force row level security;

-- The UTC day an instant falls on, as a DateKey. Spelled out rather than left to the
-- session's TimeZone, which the old view silently depended on.
create or replace function public.witness_day(p_ms bigint) returns text
  language sql
  stable
  set search_path = ''
as $$
  select to_char(to_timestamp(p_ms / 1000.0) at time zone 'UTC', 'YYYY-MM-DD')
$$;

-- The latest beat already compacted, per user: what the oldest remaining raw beat
-- measures its gap back to.
create or replace view public.witness_compacted_until as
select user_id, max(last_beat) as last_beat
  from (select user_id, ended_at as last_beat from public.witness_spans
        union all
        select user_id, last_beat_at from public.witness_days) compacted
 group by user_id;

-- Compact everything older than the two thresholds, counted in whole UTC days back from
-- p_now. Idempotent: beats and spans are moved, not copied, in one transaction, so a
-- second run the same day finds nothing to do. Returns the rows it moved.
create or replace function public.compact_witness_beats(
  p_span_after_days  integer default 30,
  p_total_after_days integer default 90,
  p_now              bigint  default public.epoch_ms()
) returns table (beats_to_spans bigint, spans_to_days bigint)
  language plpgsql
  set search_path = ''
as $$
declare
  v_today       date := (to_timestamp(p_now / 1000.0) at time zone 'UTC')::date;
  v_span_cutoff bigint := (extract(epoch from
                            ((v_today - p_span_after_days)::timestamp at time zone 'UTC'))
                           * 1000)::bigint;
  v_day_cutoff  text := to_char(v_today - p_total_after_days, 'YYYY-MM-DD');
begin
  if p_span_after_days < 1 or p_total_after_days < p_span_after_days then
    raise exception 'raw beats must outlive a day, and spans must outlive raw beats';
  end if;

  -- Raw beats into spans. A run breaks where a gap exceeds 45 seconds or the UTC day
  -- changes, so a span never straddles a day and its sum belongs to one date.
  with old as (
    select b.id, b.user_id, b.beat_at,
           coalesce(lag(b.beat_at) over (partition by b.user_id order by b.beat_at, b.id),
                    c.last_beat) as prev
      from public.witness_beats b
      left join public.witness_compacted_until c using (user_id)
     where b.beat_at < v_span_cutoff
  ), marked as (
    select old.*, public.witness_day(beat_at) as beat_date,
           case when prev is null
                  or beat_at - prev > 45000
                  or public.witness_day(prev) <> public.witness_day(beat_at)
                then 1 else 0 end as starts_run,
           -- Not coalesce(least(...), 0): least() skips NULLs, so a first-ever beat
           -- would be credited 45 seconds it never vouched for.
           case when prev is null then 0 else least(beat_at - prev, 45000) end as credit
      from old
  ), runs as (
    select marked.*,
           sum(starts_run) over (partition by user_id order by beat_at, id) as run
      from marked
  ), spans as (
    insert into public.witness_spans (user_id, beat_date, started_at, ended_at, witnessed_ms)
    select user_id, min(beat_date), min(beat_at), max(beat_at), sum(credit)
      from runs
     group by user_id, run
  )
  delete from public.witness_beats where id in (select id from old);
  get diagnostics beats_to_spans = row_count;

  -- Spans into daily totals. The upsert only matters if a day was ever compacted in two
  -- passes; beats cannot be recorded in the past, so normally each day arrives once.
  with moved as (
    delete from public.witness_spans where beat_date < v_day_cutoff
    returning user_id, beat_date, witnessed_ms, ended_at
  )
  insert into public.witness_days (user_id, beat_date, witnessed_ms, last_beat_at)
  select user_id, beat_date, sum(witnessed_ms), max(ended_at)
    from moved
   group by user_id, beat_date
  on conflict (user_id, beat_date) do update
     set witnessed_ms = public.witness_days.witnessed_ms + excluded.witnessed_ms,
         last_beat_at = greatest(public.witness_days.last_beat_at, excluded.last_beat_at);
  get diagnostics spans_to_days = row_count;

  return next;
end
$$;

revoke all on function public.compact_witness_beats(integer, integer, bigint) from public;

-- The report reads all three tiers, and gives the numbers the raw-only view gave. The
-- oldest remaining raw beat measures back to the last compacted one rather than to
-- nothing, which is what keeps compaction from losing up to 45 seconds a night.
create or replace view public.witnessed_time as
with raw as (
  select b.user_id, b.beat_at,
         coalesce(lag(b.beat_at) over (partition by b.user_id order by b.beat_at, b.id),
                  c.last_beat) as prev
    from public.witness_beats b
    left join public.witness_compacted_until c using (user_id)
)
select user_id, beat_date, sum(credit) as witnessed_ms
  -- A beat with nothing before it vouches for nothing, and is filtered rather than fed to
  -- least(), which would skip the NULL and credit it the full 45 seconds.
  from (select user_id, public.witness_day(beat_at) as beat_date,
               least(beat_at - prev, 45000) as credit
          from raw where prev is not null
        union all
        select user_id, beat_date, witnessed_ms from public.witness_spans
        union all
        select user_id, beat_date, witnessed_ms from public.witness_days) tiers
 group by user_id, beat_date
having sum(credit) > 0;
