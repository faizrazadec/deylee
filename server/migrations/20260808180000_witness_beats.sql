-- Witnessed time: the server's own record of having heard from a live timer.
--
-- A heartbeat can only be recorded in the present — the server stamps each beat
-- with its own clock on arrival, so no request made today can claim to have been
-- witnessed yesterday. Hours then split into two honest categories: witnessed
-- (a live client was heard throughout) and merely claimed (filed afterwards,
-- which offline work legitimately is). The beat carries nothing but "a timer is
-- running": no app names, no titles, no content of any kind — hours, never how.
--
-- Append-only by construction: the API role gets no grant at all, exactly like
-- audit_marks. The one way in is the SECURITY DEFINER function below, which
-- reads the caller's identity from the transaction's tenancy variable and
-- ignores every opinion the client might offer about time.

create table if not exists public.witness_beats (
  id        bigint generated always as identity primary key,
  user_id   uuid   not null references public.app_users(id) on delete cascade,
  device_id uuid,
  -- The server's clock, and only the server's clock.
  beat_at   bigint not null default public.epoch_ms()
);

create index if not exists witness_beats_by_user_time
  on public.witness_beats (user_id, beat_at);

alter table public.witness_beats enable row level security;

-- Record a beat for the signed-in user, at most one per twenty seconds.
--
-- The floor makes the table's growth boring — a client beating every thirty
-- seconds writes ~1200 rows a day at most — and turns a malicious flood into a
-- no-op rather than a storage bill. Returns whether a row was written, so the
-- endpoint can answer honestly without the client learning anything it could
-- not compute itself.
create or replace function public.record_witness_beat(p_device_id uuid)
  returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user uuid := public.current_app_user();
  v_now  bigint := public.epoch_ms();
begin
  if v_user is null then
    raise exception 'no-tenant' using errcode = 'check_violation';
  end if;
  if exists (
    select 1 from public.witness_beats
     where user_id = v_user and beat_at > v_now - 20000
  ) then
    return false;
  end if;
  insert into public.witness_beats (user_id, device_id, beat_at)
  values (v_user, p_device_id, v_now);
  return true;
end
$$;

revoke all on function public.record_witness_beat(uuid) from public;
grant execute on function public.record_witness_beat(uuid) to deylee_api;

-- The report gains its second column: witnessed milliseconds per user per day,
-- server-clock days (UTC). Beats merge into intervals — each beat vouches for
-- at most 45 seconds back, so a stopped timer stops accruing within a minute.
create or replace view public.witnessed_time as
select
  user_id,
  to_char(to_timestamp(beat_at / 1000.0), 'YYYY-MM-DD') as beat_date,
  sum(least(beat_at - lag, 45000)) as witnessed_ms
from (
  select user_id, beat_at,
         lag(beat_at) over (partition by user_id order by beat_at) as lag
  from public.witness_beats
) beats
where lag is not null
group by user_id, to_char(to_timestamp(beat_at / 1000.0), 'YYYY-MM-DD');
