-- Deylee — actually sweep the refresh tokens the index was built for.
--
-- `refresh_tokens_expiry` has existed since the table did, with a comment saying the
-- rows it covers are swept on a schedule. Nothing swept them. Every rotation inserts a
-- successor and marks its predecessor `replaced_by`, so the table only grows — roughly
-- a row per device per hour, for ever, each holding a SHA-256 and a device id for
-- sessions that ended months ago.
--
-- Not a vulnerability: expired and revoked rows are refused at use. It is unbounded
-- growth, and keeping dead session records indefinitely is a data-minimisation problem
-- of its own for something sold to companies.

-- ---------------------------------------------------------------------------
-- The sweep
--
-- SECURITY DEFINER because `deylee_api` is granted select, insert and update and
-- deliberately not delete. That grant is the right shape and this does not widen it:
-- the role can ask for the sweep, not for a DELETE of its own choosing.
--
-- The grace window is the whole design. A row is not dead when it expires — it is
-- dead when nobody can still learn anything from it. `auth_rotate_refresh_token`
-- reports a presented-but-already-replaced token as `replayed` and revokes the whole
-- chain, which is the signal that a token was stolen. Delete the row and that same
-- request answers `unknown` instead: the theft still fails, but it stops being
-- distinguishable from a client sending nonsense, and the alert is gone.
--
-- So the window is counted from expiry, not from replacement, and is long enough that
-- a chain outlives the sessions built on it.
-- ---------------------------------------------------------------------------

-- `bigint`, not `integer`. The driver binds a Swift Int as int8, so an `integer`
-- parameter matches no overload and every call fails with "function does not exist" —
-- which the API's error mapping then reports as an opaque 500.
create or replace function public.auth_sweep_expired_refresh_tokens(
  p_grace_days bigint default 30
) returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_cutoff bigint;
  v_count  integer;
begin
  -- Milliseconds, matching `expires_at` and EpochMs everywhere else.
  v_cutoff := public.epoch_ms() - (p_grace_days * 86400000);

  delete from public.refresh_tokens where expires_at < v_cutoff;
  get diagnostics v_count = row_count;
  return v_count;
end
$$;

revoke all on function public.auth_sweep_expired_refresh_tokens(bigint) from public;
grant execute on function public.auth_sweep_expired_refresh_tokens(bigint) to deylee_api;

-- ---------------------------------------------------------------------------
-- The schedule
--
-- Conditional, because `scripts/dev-db.sh` replays every migration into a stock
-- `postgres:17-alpine` container, which has no pg_cron. A hard `create extension`
-- here would make the development database impossible to build — and the sweep is
-- the part that matters. Where cron is absent the function is still installed and can
-- be called by hand or from a job runner.
--
-- Daily rather than hourly: nothing here is urgent, and a sweep that runs while a
-- rotation is in flight competes for the same rows.
-- ---------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;

    -- Idempotent: unschedule first, so re-running this migration does not leave two
    -- jobs sweeping the same table.
    perform cron.unschedule('deylee-sweep-refresh-tokens')
      where exists (
        select 1 from cron.job where jobname = 'deylee-sweep-refresh-tokens'
      );

    perform cron.schedule(
      'deylee-sweep-refresh-tokens',
      '17 3 * * *',
      'select public.auth_sweep_expired_refresh_tokens()'
    );
  else
    raise notice 'pg_cron not available: sweep function installed, not scheduled';
  end if;
end
$$;
