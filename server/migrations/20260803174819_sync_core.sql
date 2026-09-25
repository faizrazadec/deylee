-- Deylee — sync core.
--
-- v1 is single-user, multi-device: one person's Mac, iPhone, browser and
-- whatever ships next, all holding the same history. Organisations and roles
-- arrive in a later migration and are deliberately absent here. Every table
-- already carries user_id, so adding org_id later widens the tenancy check
-- rather than reshaping rows that customers depend on.
--
-- Four rules hold this schema together:
--
--  * Identifiers come from the client, never the server. Two devices offline at
--    the same moment must be able to create rows that cannot collide, which an
--    integer sequence can never promise.
--  * Instants are UTC epoch milliseconds, matching EpochMs in DeyleeKit, so a
--    value crosses the wire and lands on disk with no conversion anywhere. The
--    generated timestamptz columns are for SQL reporting only; nothing writes
--    them and nothing should read them back into the app.
--  * Rows are tombstoned, never deleted. A DELETE that fails to reach a sleeping
--    laptop resurrects the row on that machine's next sync.
--  * No table stores a total. Same rule DeyleeKit enforces, same reason: totals
--    summed from segments survive an edit, a crash and a clock change. A stored
--    counter does not.

create extension if not exists btree_gist;

-- Transaction time as epoch milliseconds. now() rather than clock_timestamp() so
-- every row written by one statement agrees on when it happened.
create or replace function public.epoch_ms()
  returns bigint
  language sql
  stable
  set search_path = ''
as $$ select (extract(epoch from now()) * 1000)::bigint $$;

-- One sequence shared by every syncable table.
--
-- Sharing it means a client tracks a single cursor rather than one per table,
-- and a pull returns days and segments already interleaved in commit order.
create sequence public.sync_seq;

-- seq is the server's ordering for the pull cursor and nothing else.
--
-- It deliberately does NOT touch updated_at: that column is the client's own
-- claim about when it made the edit, and last-write-wins compares those claims.
-- Overwriting it here would make every synced row look freshly edited, and the
-- stale device would win every conflict.
create or replace function public.assign_sync_seq()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  new.seq := nextval('public.sync_seq');
  return new;
end
$$;

-- ---------------------------------------------------------------------------
-- profiles
--
-- The timezone is not decoration. Day boundaries are local, so a report that
-- says "hours on 3 August" is wrong for a team split across Berlin and Karachi
-- unless the server knows where each person was standing.
--
-- Rows are created by the sync API on first contact rather than by a trigger on
-- auth.users, which keeps this migration clear of privileges in the auth schema
-- and keeps profile creation somewhere a test can reach.
-- ---------------------------------------------------------------------------

create table public.profiles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  timezone   text   not null default 'UTC',
  created_at bigint not null default public.epoch_ms(),
  updated_at bigint not null default public.epoch_ms()
);

-- ---------------------------------------------------------------------------
-- days
--
-- `date` is a DateKey — the calendar day as the client's local zone saw it,
-- never derived on the server. target_minutes is snapshotted per day so that
-- changing the daily goal does not silently rewrite what past days were
-- measured against.
-- ---------------------------------------------------------------------------

create table public.days (
  id             uuid    primary key,
  user_id        uuid    not null references auth.users(id) on delete cascade,
  date           text    not null,
  target_minutes integer not null,
  ended_at       bigint,
  created_at     bigint  not null default public.epoch_ms(),
  updated_at     bigint  not null default public.epoch_ms(),
  deleted_at     bigint,
  seq            bigint  not null,

  constraint days_date_is_a_datekey check (date ~ '^\d{4}-\d{2}-\d{2}$'),
  -- DeyleeKit saturates rather than traps on values that reach disk; the
  -- equivalent here is refusing the nonsense at the door.
  constraint days_target_in_range check (target_minutes between 0 and 1440)
);

-- Partial, so a tombstoned day does not block the same date being recreated.
create unique index days_one_live_row_per_date
  on public.days (user_id, date)
  where deleted_at is null;

create index days_pull_cursor on public.days (user_id, seq);

create trigger days_assign_sync_seq
  before insert or update on public.days
  for each row execute function public.assign_sync_seq();

-- ---------------------------------------------------------------------------
-- segments
--
-- day_date is denormalised rather than a foreign key to days, on purpose. Sync
-- delivers rows in commit order, not dependency order: a segment can reach the
-- server before the day it belongs to, and a foreign key would reject it and
-- strand the client in a retry loop it cannot resolve on its own.
-- ---------------------------------------------------------------------------

create table public.segments (
  id         uuid   primary key,
  user_id    uuid   not null references auth.users(id) on delete cascade,
  day_date   text   not null,
  type       text   not null,
  started_at bigint not null,
  ended_at   bigint,
  note       text,
  created_at bigint not null default public.epoch_ms(),
  updated_at bigint not null default public.epoch_ms(),
  deleted_at bigint,
  seq        bigint not null,

  -- Reporting only. Generated, so they cannot drift from the epoch columns.
  started_at_ts timestamptz generated always as (to_timestamp(started_at / 1000.0)) stored,
  ended_at_ts   timestamptz generated always as (to_timestamp(ended_at   / 1000.0)) stored,

  constraint segments_type_known      check (type in ('work', 'break')),
  constraint segments_date_is_datekey check (day_date ~ '^\d{4}-\d{2}-\d{2}$'),
  constraint segments_range_ordered   check (ended_at is null or ended_at > started_at),
  constraint segments_note_bounded    check (note is null or length(note) <= 2000)
);

-- The invariant, enforced by the database rather than hoped for by six clients.
--
-- Overlap.swift checks this before a local write, but with two devices racing
-- offline, application code cannot be the last word. An open segment is an
-- unbounded range, so this one constraint also enforces "at most one segment
-- open per user": two open segments both run to infinity, so they necessarily
-- overlap and the second is refused.
--
-- Tombstones are excluded — deleted time is not occupied time.
alter table public.segments
  add constraint segments_never_overlap
  exclude using gist (
    user_id with =,
    int8range(started_at, ended_at) with &&
  ) where (deleted_at is null);

create index segments_pull_cursor on public.segments (user_id, seq);

create index segments_by_local_day
  on public.segments (user_id, day_date)
  where deleted_at is null;

create trigger segments_assign_sync_seq
  before insert or update on public.segments
  for each row execute function public.assign_sync_seq();

-- ---------------------------------------------------------------------------
-- Row-level security
--
-- Enabled in the same migration that creates each table, never a later one. The
-- publishable key is only safe because of what follows, and a table that exists
-- for even one deploy without a policy is a table readable by anyone holding a
-- key that ships inside the app.
--
-- The sync API talks to Postgres with the secret key and bypasses all of this.
-- These policies are the backstop for that, and what would let a browser client
-- read its own rows directly if we ever want it to.
--
-- auth.uid() is wrapped in a scalar subquery so the planner evaluates it once
-- per statement rather than once per row.
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.days     enable row level security;
alter table public.segments enable row level security;

create policy profiles_are_private on public.profiles
  for all to authenticated
  using      ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy days_are_private on public.days
  for all to authenticated
  using      ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy segments_are_private on public.segments
  for all to authenticated
  using      ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
