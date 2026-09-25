-- Deylee — our own identity, replacing Supabase Auth.
--
-- Google is the identity provider directly. It answers exactly one question —
-- who is this — and its ID token expires in about an hour, which makes it proof
-- of identity and not a session. Everything a session needs is therefore ours to
-- build: a stable user row, an access token we sign, and a refresh token we can
-- rotate and revoke.
--
-- Two consequences fall out of that and both are handled here:
--
--  * `auth.users` is no longer the owner of anything. The foreign keys move to
--    `app_users`, which is keyed on Google's `sub` rather than on an email
--    address, because people change their email and Google keeps the subject
--    identifier stable. Matching on email would eventually hand one person
--    another person's hours.
--  * `auth.uid()` no longer resolves, so every policy written against it now
--    matches nothing. Rather than leave dead policies in place, tenancy moves to
--    a session variable the API sets per transaction.

-- ---------------------------------------------------------------------------
-- app_users
--
-- `profiles` is dropped rather than kept alongside this: it existed only to hang
-- a timezone off an `auth.users` row, and that column belongs here now. It is
-- empty, so nothing is lost.
-- ---------------------------------------------------------------------------

drop table if exists public.profiles;

create table public.app_users (
  id             uuid primary key default gen_random_uuid(),

  -- Google's subject identifier. Stable for the life of the account, unlike the
  -- email address, which is why this and not the email is the natural key.
  google_sub     text    not null unique,

  email          text    not null,
  email_verified boolean not null default false,
  display_name   text,

  -- Day boundaries are local. A report covering "4 August" is wrong for anyone
  -- whose day did not start when the server's did.
  timezone       text    not null default 'UTC',

  created_at     bigint  not null default public.epoch_ms(),
  updated_at     bigint  not null default public.epoch_ms(),
  last_seen_at   bigint,

  constraint app_users_email_shaped check (position('@' in email) > 1)
);

-- Sign-in looks users up by `sub` on every single request that mints a session;
-- the unique constraint above already indexes it.
create index app_users_by_email on public.app_users (lower(email));

-- ---------------------------------------------------------------------------
-- refresh_tokens
--
-- Access tokens are short-lived and stateless, so they cannot be revoked. The
-- refresh token is where control lives, which is why it is stored rather than
-- merely signed.
--
-- Only the SHA-256 of the token is kept. A stolen database dump then yields no
-- usable credential, exactly as with a password. The token itself exists in one
-- place: the client's Keychain.
--
-- `session_id` is constant across a rotation chain. On every refresh the old row
-- is marked `replaced_by` the new one; if a token that has already been replaced
-- is presented again, that is a replay of a stolen token, and the correct answer
-- is to revoke every token sharing its `session_id` rather than just that row.
-- The legitimate holder is signed out too, which is the point — they find out.
-- ---------------------------------------------------------------------------

create table public.refresh_tokens (
  id          uuid   primary key default gen_random_uuid(),
  user_id     uuid   not null references public.app_users(id) on delete cascade,
  session_id  uuid   not null,

  token_hash  bytea  not null unique,

  device_id   uuid,
  user_agent  text,

  issued_at   bigint not null default public.epoch_ms(),
  expires_at  bigint not null,
  revoked_at  bigint,
  replaced_by uuid   references public.refresh_tokens(id) on delete set null,

  constraint refresh_tokens_outlive_issue check (expires_at > issued_at),
  constraint refresh_tokens_hash_is_sha256 check (octet_length(token_hash) = 32)
);

-- The lookup on every refresh: find a live token for this user's session.
create index refresh_tokens_live
  on public.refresh_tokens (user_id, session_id)
  where revoked_at is null;

-- Expired rows are swept on a schedule; this is the index that sweep uses.
create index refresh_tokens_expiry on public.refresh_tokens (expires_at)
  where revoked_at is null;

-- ---------------------------------------------------------------------------
-- Repoint the syncable tables
--
-- The column type and name do not change, so no data moves and no client notices.
-- Only what `user_id` points at changes.
-- ---------------------------------------------------------------------------

alter table public.days     drop constraint days_user_id_fkey;
alter table public.segments drop constraint segments_user_id_fkey;

alter table public.days
  add constraint days_user_id_fkey
  foreign key (user_id) references public.app_users(id) on delete cascade;

alter table public.segments
  add constraint segments_user_id_fkey
  foreign key (user_id) references public.app_users(id) on delete cascade;

-- ---------------------------------------------------------------------------
-- Tenancy without Supabase Auth
--
-- `auth.uid()` reads a claim out of a Supabase-issued JWT. Nothing issues those
-- any more, so it is permanently null and the old policies would match no row
-- ever. That fails closed, which is the right direction, but a policy that can
-- never be true is a policy nobody can reason about.
--
-- Tenancy now reads a session variable that the API sets inside each request's
-- transaction:
--
--     set local app.user_id = '<the id from the verified access token>';
--
-- `set local` matters: it reverts at commit, so a pooled connection cannot carry
-- one request's identity into the next. The `true` argument to current_setting
-- makes an unset variable return null instead of raising, so a connection that
-- forgets to set it reads nothing rather than erroring in a way that might be
-- caught and ignored.
--
-- This only binds if the API connects as a role that does not bypass RLS. The
-- role below exists for that; a login user is created out of band and granted
-- it, so that no password ever lands in this repository.
-- ---------------------------------------------------------------------------

create or replace function public.current_app_user()
  returns uuid
  language sql
  stable
  set search_path = ''
as $$ select nullif(current_setting('app.user_id', true), '')::uuid $$;

drop policy if exists days_are_private     on public.days;
drop policy if exists segments_are_private on public.segments;

alter table public.app_users      enable row level security;
alter table public.refresh_tokens enable row level security;

create policy days_are_own on public.days
  for all
  using      (user_id = public.current_app_user())
  with check (user_id = public.current_app_user());

create policy segments_are_own on public.segments
  for all
  using      (user_id = public.current_app_user())
  with check (user_id = public.current_app_user());

create policy app_users_are_own on public.app_users
  for all
  using      (id = public.current_app_user())
  with check (id = public.current_app_user());

-- Deliberately no policy. Refresh tokens are never read through a user-scoped
-- connection — only by the auth routes, which run as the owner. RLS enabled with
-- no policy is a denial, and that is the intent.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'deylee_api') then
    create role deylee_api nologin;
  end if;
end
$$;

grant usage on schema public to deylee_api;
grant select, insert, update on public.days, public.segments, public.app_users to deylee_api;
grant select, insert, update on public.refresh_tokens to deylee_api;
grant usage, select on sequence public.sync_seq to deylee_api;
