-- Witnessed time for one of the caller's local days, for hour slips.
--
-- The witnessed_time view counts by UTC day, which is the wrong day for anybody not on
-- UTC: an hour slip lists the user's own dates. This answers for an arbitrary window
-- instead, [p_from, p_to) in epoch milliseconds, which the API computes as one local day
-- from the user's zone.
--
-- Exact while the evidence is fine-grained, by the compaction tiers:
--
--   raw beats   each vouches for the gap back to the one before it, capped at 45 s — the
--               interval (beat_at - credit, beat_at] is clipped to the window
--   spans       one span is one unbroken run, so its credit is the contiguous interval
--               (ended_at - witnessed_ms, ended_at], clipped the same way
--   day totals  kept only by UTC date, with no instants left to clip. Counted when their
--               UTC date is the requested local date, and reported as approximate
--
-- SECURITY DEFINER because deylee_api holds no grant on the witness tables; the caller's
-- identity comes from the transaction's tenancy variable, never from an argument.

create or replace function public.hour_slip_witnessed(p_from bigint, p_to bigint, p_date text)
  returns table (witnessed_ms bigint, approximate boolean)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_user uuid := public.current_app_user();
  v_exact bigint;
  v_daily bigint;
begin
  if v_user is null then
    raise exception 'no-tenant' using errcode = 'check_violation';
  end if;

  with beats as (
    select b.beat_at,
           coalesce(
             lag(b.beat_at) over (order by b.beat_at, b.id),
             -- The beat before the window's first, wherever it is: raw, then compacted.
             (select max(p.beat_at) from public.witness_beats p
               where p.user_id = v_user and p.beat_at < p_from - 45000),
             (select max(s.ended_at) from public.witness_spans s
               where s.user_id = v_user and s.ended_at < p_from - 45000),
             (select max(d.last_beat_at) from public.witness_days d
               where d.user_id = v_user and d.last_beat_at < p_from - 45000)
           ) as prev
      from public.witness_beats b
     where b.user_id = v_user
       and b.beat_at >= p_from - 45000
       and b.beat_at < p_to + 45000
  ), intervals as (
    select beat_at - least(beat_at - prev, 45000) as starts, beat_at as ends
      from beats where prev is not null
    union all
    select s.ended_at - s.witnessed_ms, s.ended_at
      from public.witness_spans s
     where s.user_id = v_user and s.ended_at > p_from and s.ended_at - s.witnessed_ms < p_to
  )
  select coalesce(sum(greatest(0, least(ends, p_to) - greatest(starts, p_from))), 0)
    into v_exact
    from intervals;

  select coalesce(sum(d.witnessed_ms), 0) into v_daily
    from public.witness_days d
   where d.user_id = v_user and d.beat_date = p_date;

  return query select v_exact + v_daily, v_daily > 0;
end
$$;

revoke all on function public.hour_slip_witnessed(bigint, bigint, text) from public;
grant execute on function public.hour_slip_witnessed(bigint, bigint, text) to deylee_api;
