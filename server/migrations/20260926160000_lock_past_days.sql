-- Past days are locked: the hours of a day that has ended can no longer be rewritten.
--
-- The integrity migration made edits ink rather than walls — allowed, and noted. This
-- turns the walls on for the one thing that matters most: once a day is over, by the
-- server's clock, its recorded work and break time is final. The server's clock and not
-- the client's, so moving a Mac's date back to yesterday reopens nothing; the Mac is told
-- `locked` on its next sync and handed the server's copy to put back.
--
-- A day locks two hours after its midnight, in the user's time zone. The zone is the one
-- the client sends with each sync (app.time_zone), falling back to the one recorded at
-- sign-in and then to UTC: a zone stored once goes stale the day somebody flies west, and
-- would lock today while it is still today where they are.
--
-- Still allowed on a locked day, because refusing them loses honest time:
--
--   closing an open segment   the timer, when a laptop slept across midnight
--   discarding one            crash recovery; an open segment holds no recorded hours
--   editing a note            words about the time, not the time
--   a segment never seen      work recorded offline and synced late: accepted, and marked
--                             as a late claim, so it reads as claimed rather than witnessed
--
-- An *open* segment arriving for a locked day is refused. No honest client sends one — the
-- timer closes and splits at midnight before it syncs — and accepting it would let a clock
-- set back record an unmarked yesterday, since closing is not marked.

-- When `p_date` locks for `p_user`, in epoch milliseconds. SECURITY DEFINER to read the
-- sign-in time zone from app_users, which the API role cannot select.
create or replace function public.day_lock_at(p_user uuid, p_date text) returns bigint
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_zone text := coalesce(
    nullif(current_setting('app.time_zone', true), ''),
    (select timezone from public.app_users where id = p_user),
    'UTC');
  v_midnight timestamptz;
begin
  begin
    -- Calendar arithmetic in the zone: midnight after a 23- or 25-hour day is where the
    -- zone says it is, never a fixed 86,400,000 ms after the last one.
    v_midnight := (p_date::date + 1)::timestamp at time zone v_zone;
  exception when invalid_parameter_value then
    v_midnight := (p_date::date + 1)::timestamp at time zone 'UTC';
  end;
  return (extract(epoch from v_midnight + interval '2 hours') * 1000)::bigint;
end
$$;

revoke all on function public.day_lock_at(uuid, text) from public;
grant execute on function public.day_lock_at(uuid, text) to deylee_api;

create or replace function public.refuse_locked_day_change() returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_now bigint := public.epoch_ms();
begin
  if tg_op = 'INSERT' then
    if new.ended_at is null and new.deleted_at is null
       and v_now >= public.day_lock_at(new.user_id, new.day_date) then
      raise exception 'day-locked' using errcode = 'check_violation';
    end if;
    return new;
  end if;

  -- The timer closing what it opened, or crash recovery discarding it: only ended_at or
  -- deleted_at move, and the note may ride along.
  if old.ended_at is null
     and (new.started_at, new.type, new.day_date)
         is not distinct from (old.started_at, old.type, old.day_date) then
    return new;
  end if;
  -- A note, and nothing about the time.
  if (new.started_at, new.ended_at, new.type, new.day_date, new.deleted_at)
     is not distinct from (old.started_at, old.ended_at, old.type, old.day_date, old.deleted_at)
  then
    return new;
  end if;
  -- Both ends: a segment may neither leave a locked day nor be moved onto one.
  if v_now >= public.day_lock_at(old.user_id, old.day_date)
     or v_now >= public.day_lock_at(new.user_id, new.day_date) then
    raise exception 'day-locked' using errcode = 'check_violation';
  end if;
  return new;
end
$$;

drop trigger if exists segments_refuse_locked_day on public.segments;
create trigger segments_refuse_locked_day
  before insert or update on public.segments
  for each row execute function public.refuse_locked_day_change();

-- A closed segment filed onto a day that has already locked is a late claim too, not only
-- one filed more than 48 hours after it ended. Replaces the body the integrity migration
-- installed; the trigger itself is unchanged.
create or replace function public.note_late_claim() returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.ended_at is not null
     and (public.epoch_ms() - new.ended_at > 172800000
          or public.epoch_ms() >= public.day_lock_at(new.user_id, new.day_date)) then
    insert into public.audit_marks (user_id, row_table, row_id, day_date, kind, after)
    values (new.user_id, 'segments', new.id, new.day_date, 'late-claim',
            jsonb_build_object('started_at', new.started_at, 'ended_at', new.ended_at,
                               'filed_at', public.epoch_ms()));
  end if;
  return new;
end
$$;
