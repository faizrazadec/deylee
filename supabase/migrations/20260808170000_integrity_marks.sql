-- Integrity: the server stops believing and starts keeping notes.
--
-- Two ideas, both living in the database so that every client — this Mac app, the
-- planned iOS app, and anyone with a stolen bearer token and curl — faces the same
-- rules through the only door there is.
--
-- BOUNDS refuse the absurd at the door: a segment longer than a working day has
-- any honest person asleep, and a timestamp in the future is a clock nobody
-- should trust. Refusals raise class 23, which the sync route already maps to a
-- per-row rejection — and never class 28, which a driver reads as its own login
-- failing (see the sign_in_error_code migration).
--
-- MARKS are ink, not walls. Editing history is allowed — a person fixing a
-- mistaken entry is a feature — but every material change to hours that were
-- already recorded leaves a row in audit_marks, written by triggers the caller
-- cannot reach. The table has NO grant to deylee_api: the API cannot select,
-- insert, update or delete it, so no token, however obtained, can touch the ink.
-- The trigger functions are SECURITY DEFINER for exactly that reason — the
-- writer is the schema owner, never the caller.
--
-- What is deliberately NOT marked: closing an open segment (that is the timer
-- doing its job), tombstoning a segment that never closed (no recorded hours are
-- lost), and last-write-wins echoes (the WHERE clause stops the update firing).

-- ---------------------------------------------------------------------------
-- The ink
-- ---------------------------------------------------------------------------

create table if not exists public.audit_marks (
  id        bigint generated always as identity primary key,
  user_id   uuid   not null references public.app_users(id) on delete cascade,
  row_table text   not null,
  row_id    uuid   not null,
  -- Denormalised so a per-day report needs no join through the row itself,
  -- which may since have been tombstoned or re-dated.
  day_date  text,
  kind      text   not null,
  before    jsonb,
  after     jsonb,
  noted_at  bigint not null default public.epoch_ms(),

  constraint audit_marks_table_known check (row_table in ('segments', 'days')),
  constraint audit_marks_kind_known  check (kind in ('edited', 'deleted', 'late-claim'))
);

create index if not exists audit_marks_by_user_day
  on public.audit_marks (user_id, day_date);

-- Belt and braces: even if a grant appears by mistake, RLS with no policy
-- matches nothing.
alter table public.audit_marks enable row level security;

-- ---------------------------------------------------------------------------
-- Bounds
-- ---------------------------------------------------------------------------

-- Sixteen hours. Generous enough for any honest day, short enough that a forged
-- "yesterday, 9:00 to 9:00" cannot claim a day in one row. The app's own UI
-- never produces more; only a hand-written row can.
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'segments_duration_sane') then
    alter table public.segments add constraint segments_duration_sane
      check (ended_at is null or ended_at - started_at <= 57600000);
  end if;
end $$;

-- The future is refused with five minutes' grace for honest clock skew. This
-- must be a trigger, not a CHECK: a CHECK is re-evaluated on restores and
-- would refuse perfectly good history for having once been near "now".
create or replace function public.refuse_future_time() returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_limit bigint := public.epoch_ms() + 300000;
begin
  if new.started_at > v_limit
     or (new.ended_at is not null and new.ended_at > v_limit) then
    raise exception 'in-the-future' using errcode = 'check_violation';
  end if;
  return new;
end
$$;

drop trigger if exists segments_refuse_future on public.segments;
create trigger segments_refuse_future
  before insert or update on public.segments
  for each row execute function public.refuse_future_time();

-- ---------------------------------------------------------------------------
-- Marks: segments
-- ---------------------------------------------------------------------------

create or replace function public.note_segment_change() returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if old.ended_at is null then
    -- The open segment. Closing it — ended_at gaining a value while everything
    -- else stands still — is the timer's own writing and earns no ink. So does
    -- discarding it: an open segment has no recorded hours to protect. Only
    -- reshaping it while it runs (a backdated start, a changed type) is an edit.
    if (new.started_at, new.type, new.day_date)
       is not distinct from (old.started_at, old.type, old.day_date) then
      return new;
    end if;
  elsif new.deleted_at is not null and old.deleted_at is null then
    insert into public.audit_marks (user_id, row_table, row_id, day_date, kind, before)
    values (old.user_id, 'segments', old.id, old.day_date, 'deleted',
            jsonb_build_object('started_at', old.started_at, 'ended_at', old.ended_at,
                               'type', old.type));
    return new;
  end if;

  if (new.started_at, new.ended_at, new.type, new.day_date)
     is distinct from (old.started_at, old.ended_at, old.type, old.day_date) then
    insert into public.audit_marks (user_id, row_table, row_id, day_date, kind, before, after)
    values (old.user_id, 'segments', old.id, old.day_date, 'edited',
            jsonb_build_object('started_at', old.started_at, 'ended_at', old.ended_at,
                               'type', old.type, 'day_date', old.day_date),
            jsonb_build_object('started_at', new.started_at, 'ended_at', new.ended_at,
                               'type', new.type, 'day_date', new.day_date));
  end if;
  return new;
end
$$;

drop trigger if exists segments_note_change on public.segments;
create trigger segments_note_change
  after update on public.segments
  for each row execute function public.note_segment_change();

-- A closed segment arriving long after it supposedly ended. Forty-eight hours
-- of grace covers an offline weekend; an honest client syncs within minutes of
-- getting a network, so hours first filed days late are worth a note even
-- though they are accepted.
create or replace function public.note_late_claim() returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.ended_at is not null
     and public.epoch_ms() - new.ended_at > 172800000 then
    insert into public.audit_marks (user_id, row_table, row_id, day_date, kind, after)
    values (new.user_id, 'segments', new.id, new.day_date, 'late-claim',
            jsonb_build_object('started_at', new.started_at, 'ended_at', new.ended_at,
                               'filed_at', public.epoch_ms()));
  end if;
  return new;
end
$$;

drop trigger if exists segments_note_late_claim on public.segments;
create trigger segments_note_late_claim
  after insert on public.segments
  for each row execute function public.note_late_claim();

-- ---------------------------------------------------------------------------
-- Marks: days
--
-- target_minutes is snapshotted per day precisely so past days keep the goal
-- they were measured against. Changing it after the day ended is therefore
-- always worth ink; before that it is just somebody adjusting today.
-- ---------------------------------------------------------------------------

create or replace function public.note_day_change() returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if old.ended_at is null then
    return new;
  end if;
  if new.deleted_at is not null and old.deleted_at is null then
    insert into public.audit_marks (user_id, row_table, row_id, day_date, kind, before)
    values (old.user_id, 'days', old.id, old.date, 'deleted',
            jsonb_build_object('target_minutes', old.target_minutes));
  elsif new.target_minutes is distinct from old.target_minutes then
    insert into public.audit_marks (user_id, row_table, row_id, day_date, kind, before, after)
    values (old.user_id, 'days', old.id, old.date, 'edited',
            jsonb_build_object('target_minutes', old.target_minutes),
            jsonb_build_object('target_minutes', new.target_minutes));
  end if;
  return new;
end
$$;

drop trigger if exists days_note_change on public.days;
create trigger days_note_change
  after update on public.days
  for each row execute function public.note_day_change();

-- ---------------------------------------------------------------------------
-- The report
--
-- Read with psql as the schema owner; deliberately not granted to deylee_api,
-- because the report is for the operator and, one day, a reporting surface with
-- its own authentication — never for the client that is being reported on.
-- ---------------------------------------------------------------------------

create or replace view public.integrity_report as
select
  u.email,
  s.user_id,
  s.day_date,
  sum(s.ended_at - s.started_at)
    filter (where s.type = 'work' and s.ended_at is not null and s.deleted_at is null)
    as claimed_work_ms,
  count(distinct m.id) as marks
from public.segments s
join public.app_users u on u.id = s.user_id
left join public.audit_marks m
  on m.user_id = s.user_id and m.day_date = s.day_date
group by u.email, s.user_id, s.day_date
order by s.day_date desc;
