-- Deylee — several ways to prove you are the same person.
--
-- Two things happen here, and they are one change seen from two sides.
--
-- Identity moves out of `app_users`. A `google_sub` column on the user row says a
-- person may sign in exactly one way, forever. Someone who signs up with a password
-- today and clicks "Continue with Google" tomorrow is one person, and the schema
-- has to be able to say so.
--
-- The auth paths move into SECURITY DEFINER functions, which fixes a bug that would
-- have broken the first real sign-in. The API connects as `deylee_api`, a role
-- deliberately subject to row-level security — but sign-in happens *before*
-- `app.user_id` exists, so the policy matched nothing: creating a user failed
-- outright, and every refresh-token lookup returned zero rows, indistinguishable
-- from a forged token. Auth cannot be tenant-scoped, because auth is what
-- establishes the tenant. Running it as the owner through a handful of named
-- functions keeps the ordinary connection restricted while letting exactly these
-- operations through.

-- pgcrypto already exists on Supabase, in the `extensions` schema rather than in
-- `public`. Every call below is qualified accordingly: these functions run with
-- `search_path = ''`, which is what stops a caller from shadowing `crypt` with
-- their own — and which also means nothing resolves implicitly.
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- user_identities
--
-- One row per way a person can sign in. `subject` is Google's `sub` for google,
-- and the lower-cased email address for password.
-- ---------------------------------------------------------------------------

create table public.user_identities (
  id            uuid   primary key default gen_random_uuid(),
  user_id       uuid   not null references public.app_users(id) on delete cascade,
  provider      text   not null,
  subject       text   not null,

  -- bcrypt, via pgcrypto. Only ever the digest; the password itself is a bind
  -- parameter that exists for one statement and is never stored.
  password_hash text,

  created_at    bigint not null default public.epoch_ms(),
  updated_at    bigint not null default public.epoch_ms(),
  last_used_at  bigint,

  constraint user_identities_provider_known check (provider in ('google', 'password')),
  constraint user_identities_unique_subject unique (provider, subject),
  -- A password identity without a hash could never authenticate; a Google identity
  -- with one implies a credential we have no business holding.
  constraint user_identities_hash_iff_password
    check ((provider = 'password') = (password_hash is not null))
);

create index user_identities_by_user on public.user_identities (user_id);

alter table public.user_identities enable row level security;
-- No policy: reached only through the functions below, which run as the owner.

-- Carry existing Google users across before the column goes.
insert into public.user_identities (user_id, provider, subject)
select id, 'google', google_sub from public.app_users where google_sub is not null;

alter table public.app_users drop constraint if exists app_users_google_sub_key;
alter table public.app_users drop column google_sub;

-- The email now links one person's several identities, so it has to be unique —
-- case-insensitively, because Alice@ and alice@ are one mailbox and treating them
-- as two accounts is how somebody ends up with their history split in half.
create unique index app_users_one_per_email on public.app_users (lower(email));

-- ---------------------------------------------------------------------------
-- Sign in with Google
--
-- Linking is safe in this direction. Google asserts it has verified the address,
-- so an existing account with that email may be adopted: whoever holds this token
-- demonstrably controls the mailbox. The reverse is refused below.
-- ---------------------------------------------------------------------------

create or replace function public.auth_sign_in_with_google(
  p_sub text, p_email text, p_email_verified boolean, p_name text, p_timezone text
) returns public.app_users
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user public.app_users;
  v_now  bigint := public.epoch_ms();
begin
  if not p_email_verified then
    raise exception 'unverified-email' using errcode = 'check_violation';
  end if;

  select u.* into v_user
    from public.app_users u
    join public.user_identities i on i.user_id = u.id
   where i.provider = 'google' and i.subject = p_sub;

  if found then
    update public.app_users set
      email        = p_email,
      display_name = coalesce(p_name, display_name),
      timezone     = coalesce(p_timezone, timezone),
      updated_at   = v_now,
      last_seen_at = v_now
     where id = v_user.id
     returning * into v_user;

    update public.user_identities set last_used_at = v_now
     where provider = 'google' and subject = p_sub;
    return v_user;
  end if;

  -- Unknown to Google here, but the address may already belong to a password
  -- account. Adopting it is the safe direction.
  select * into v_user from public.app_users where lower(email) = lower(p_email);

  if not found then
    insert into public.app_users (email, email_verified, display_name, timezone, last_seen_at)
    values (p_email, true, p_name, coalesce(p_timezone, 'UTC'), v_now)
    returning * into v_user;
  else
    update public.app_users set
      email_verified = true,
      display_name   = coalesce(display_name, p_name),
      updated_at     = v_now,
      last_seen_at   = v_now
     where id = v_user.id
     returning * into v_user;
  end if;

  insert into public.user_identities (user_id, provider, subject, last_used_at)
  values (v_user.id, 'google', p_sub, v_now);

  return v_user;
end
$$;

-- ---------------------------------------------------------------------------
-- Sign up with a password
--
-- Refusing an address that already exists is the security boundary. Auto-linking
-- in this direction would let anyone type a stranger's email, choose a password,
-- and be handed that stranger's account the moment the addresses matched — the
-- classic pre-registration takeover. Nothing here has verified that the person
-- typing owns the mailbox.
--
-- Someone who really is that person signs in with Google and adds a password from
-- Settings, through `auth_set_password` below, which is safe because the session
-- already proves who they are.
-- ---------------------------------------------------------------------------

create or replace function public.auth_sign_up_with_password(
  p_email text, p_password text, p_name text, p_timezone text
) returns public.app_users
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user public.app_users;
  v_now  bigint := public.epoch_ms();
begin
  -- bcrypt silently ignores anything past 72 bytes, which would make two different
  -- long passwords interchangeable. Refuse rather than truncate.
  if length(p_password) < 8 or octet_length(p_password) > 72 then
    raise exception 'weak-password' using errcode = 'check_violation';
  end if;

  if exists (select 1 from public.app_users where lower(email) = lower(p_email)) then
    raise exception 'email-taken' using errcode = 'unique_violation';
  end if;

  insert into public.app_users (email, email_verified, display_name, timezone, last_seen_at)
  values (p_email, false, p_name, coalesce(p_timezone, 'UTC'), v_now)
  returning * into v_user;

  insert into public.user_identities (user_id, provider, subject, password_hash, last_used_at)
  values (v_user.id, 'password', lower(p_email),
          extensions.crypt(p_password, extensions.gen_salt('bf', 12)), v_now);

  return v_user;
end
$$;

-- ---------------------------------------------------------------------------
-- Sign in with a password
--
-- One failure for "no such account" and "wrong password" alike, so the response
-- cannot be used to enumerate which addresses are registered.
-- ---------------------------------------------------------------------------

create or replace function public.auth_sign_in_with_password(
  p_email text, p_password text
) returns public.app_users
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user public.app_users;
  v_now  bigint := public.epoch_ms();
begin
  select u.* into v_user
    from public.app_users u
    join public.user_identities i on i.user_id = u.id
   where i.provider = 'password'
     and i.subject = lower(p_email)
     and i.password_hash = extensions.crypt(p_password, i.password_hash);

  if not found then
    raise exception 'invalid-credentials' using errcode = 'invalid_password';
  end if;

  update public.user_identities set last_used_at = v_now
   where user_id = v_user.id and provider = 'password';
  update public.app_users set last_seen_at = v_now where id = v_user.id
   returning * into v_user;

  return v_user;
end
$$;

-- ---------------------------------------------------------------------------
-- Add or change a password on an account already signed into.
--
-- The safe route into password sign-in for a Google user: the session has already
-- established who they are, so nothing further needs proving.
-- ---------------------------------------------------------------------------

create or replace function public.auth_set_password(
  p_user_id uuid, p_password text
) returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_email text;
  v_now   bigint := public.epoch_ms();
begin
  if length(p_password) < 8 or octet_length(p_password) > 72 then
    raise exception 'weak-password' using errcode = 'check_violation';
  end if;

  select email into v_email from public.app_users where id = p_user_id;
  if not found then
    raise exception 'no-such-user' using errcode = 'no_data_found';
  end if;

  insert into public.user_identities (user_id, provider, subject, password_hash, last_used_at)
  values (p_user_id, 'password', lower(v_email),
          extensions.crypt(p_password, extensions.gen_salt('bf', 12)), v_now)
  on conflict (provider, subject) do update
    set password_hash = excluded.password_hash, updated_at = v_now;
end
$$;

-- ---------------------------------------------------------------------------
-- Refresh tokens
--
-- Also SECURITY DEFINER, for the same reason: a refresh happens before any tenant
-- exists, so RLS would hide every row and make a valid token indistinguishable
-- from a forged one.
-- ---------------------------------------------------------------------------

create or replace function public.auth_issue_refresh_token(
  p_user_id uuid, p_session_id uuid, p_hash bytea, p_device uuid, p_expires_at bigint
) returns void
  language sql
  security definer
  set search_path = ''
as $$
  insert into public.refresh_tokens (user_id, session_id, token_hash, device_id, expires_at)
  values (p_user_id, p_session_id, p_hash, p_device, p_expires_at);
$$;

/* Rotate a refresh token, detecting replay.
 *
 * A token already replaced means two parties hold it, and the only safe reading is
 * that one of them stole it. The whole chain is revoked — the legitimate holder
 * included, which is the point, because otherwise nobody ever finds out.
 *
 * Returns an outcome rather than raising, and that is not a style preference. An
 * exception aborts the surrounding (sub)transaction, which would roll back the very
 * revocation that had just been performed: the replay would be reported while the
 * stolen token quietly stayed alive. Reporting a theft has to be the one thing that
 * cannot be undone by reporting it.
 *
 * outcome is one of 'rotated', 'unknown', 'replayed', 'expired'. Every failure
 * looks alike to the caller, which answers 401 for all of them — a client cannot
 * learn from the response whether a token ever existed.
 */
create or replace function public.auth_rotate_refresh_token(
  p_old_hash bytea, p_new_hash bytea, p_expires_at bigint
) returns table (outcome text, user_id uuid, email text, display_name text, timezone text)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_token public.refresh_tokens;
  v_user  public.app_users;
  v_new   uuid;
  v_now   bigint := public.epoch_ms();
begin
  select * into v_token from public.refresh_tokens where token_hash = p_old_hash;
  if not found then
    return query select 'unknown'::text, null::uuid, null::text, null::text, null::text;
    return;
  end if;

  if v_token.revoked_at is not null or v_token.replaced_by is not null then
    update public.refresh_tokens set revoked_at = v_now
     where session_id = v_token.session_id and revoked_at is null;
    return query select 'replayed'::text, null::uuid, null::text, null::text, null::text;
    return;
  end if;

  if v_token.expires_at <= v_now then
    return query select 'expired'::text, null::uuid, null::text, null::text, null::text;
    return;
  end if;

  insert into public.refresh_tokens (user_id, session_id, token_hash, device_id, expires_at)
  values (v_token.user_id, v_token.session_id, p_new_hash, v_token.device_id, p_expires_at)
  returning id into v_new;

  update public.refresh_tokens set replaced_by = v_new where id = v_token.id;

  select * into v_user from public.app_users where id = v_token.user_id;
  return query select 'rotated'::text, v_user.id, v_user.email, v_user.display_name, v_user.timezone;
end
$$;

/* The session a stored token belongs to, so a rotated pair keeps its chain. */
create or replace function public.auth_session_for_token(p_hash bytea)
  returns uuid
  language sql
  security definer
  stable
  set search_path = ''
as $$ select session_id from public.refresh_tokens where token_hash = p_hash $$;

create or replace function public.auth_revoke_session(p_session_id uuid)
  returns void
  language sql
  security definer
  set search_path = ''
as $$
  update public.refresh_tokens set revoked_at = public.epoch_ms()
   where session_id = p_session_id and revoked_at is null;
$$;

-- ---------------------------------------------------------------------------
-- Only these. Everything the API may do before a tenant exists is enumerated
-- here and nowhere else; its ordinary connection stays restricted.
-- ---------------------------------------------------------------------------

revoke all on function public.auth_sign_in_with_google(text, text, boolean, text, text) from public;
revoke all on function public.auth_sign_up_with_password(text, text, text, text) from public;
revoke all on function public.auth_sign_in_with_password(text, text) from public;
revoke all on function public.auth_set_password(uuid, text) from public;
revoke all on function public.auth_issue_refresh_token(uuid, uuid, bytea, uuid, bigint) from public;
revoke all on function public.auth_rotate_refresh_token(bytea, bytea, bigint) from public;
revoke all on function public.auth_session_for_token(bytea) from public;
revoke all on function public.auth_revoke_session(uuid) from public;

grant execute on function public.auth_sign_in_with_google(text, text, boolean, text, text) to deylee_api;
grant execute on function public.auth_sign_up_with_password(text, text, text, text) to deylee_api;
grant execute on function public.auth_sign_in_with_password(text, text) to deylee_api;
grant execute on function public.auth_set_password(uuid, text) to deylee_api;
grant execute on function public.auth_issue_refresh_token(uuid, uuid, bytea, uuid, bigint) to deylee_api;
grant execute on function public.auth_rotate_refresh_token(bytea, bytea, bigint) to deylee_api;
grant execute on function public.auth_session_for_token(bytea) to deylee_api;
grant execute on function public.auth_revoke_session(uuid) to deylee_api;
