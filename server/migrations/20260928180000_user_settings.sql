-- Settings: one row per person, so a fresh install or a lost preferences file can
-- get its preferences back from the account.
--
-- A single JSON object rather than a column per preference. Clients already treat
-- their own store as untrusted and clamp every key on the way in, so the server does
-- not have to know what `idleThresholdMinutes` means, and a client that learns a new
-- preference does not need a migration here to sync it. What the server does hold
-- the line on is shape and size, in the constraints below and in the route.
--
-- Last write wins on `updated_at`, the client's claim, exactly as segments do: the
-- server stores it unmodified because the comparison is only meaningful between two
-- client clocks. The upsert that enforces it is in routes/settings.py.
--
-- Screen capture settings are never sent (see SYNC_PROTOCOL.md), so nothing in this
-- table can switch capture on for anyone.

create table if not exists public.user_settings (
  user_id    uuid   primary key references public.app_users(id) on delete cascade,
  settings   jsonb  not null,
  updated_at bigint not null,
  constraint user_settings_is_object check (jsonb_typeof(settings) = 'object'),
  constraint user_settings_bounded   check (octet_length(settings::text) <= 16384)
);

-- In the same migration that creates the table, never a later one.
alter table public.user_settings enable row level security;
alter table public.user_settings force row level security;

create policy user_settings_are_own on public.user_settings
  for all
  using      (user_id = public.current_app_user())
  with check (user_id = public.current_app_user());

-- No delete: resetting settings is writing the defaults, which reaches every device
-- the same way any other change does.
grant select, insert, update on public.user_settings to deylee_api;
