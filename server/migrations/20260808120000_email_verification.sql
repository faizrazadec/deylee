-- Deylee — email verification for password sign-up.
--
-- Signing up no longer creates an account. The request is parked here, a code is
-- mailed, and `app_users` is written only once that code comes back. The change is
-- small to describe and closes a critical hole:
--
-- Before this, sign-up wrote a row with `email_verified = false` and nothing in the
-- repository ever set it true except Google. `auth_sign_in_with_google` adopts an
-- existing row by address, so anyone could register a stranger's address, wait for
-- the real owner to sign in with Google, and keep a working password on the account
-- they were handed. The column existed; nothing acted on it.
--
-- The fix is not a check bolted onto that path — it is that an unverified account
-- can no longer exist, so there is nothing for Google to adopt. `pending_signups`
-- is deliberately a separate table rather than a flag: rows here are not accounts,
-- own nothing, and are deleted the moment they are used or expire.
--
-- Two defences are kept anyway, because rows written before this migration are
-- already out there:
--
--   * `auth_sign_in_with_google` now drops password identities when it adopts a row
--     that was never verified. The person who set that password never proved they
--     own the mailbox, so the credential has no standing.
--   * A one-off cleanup at the bottom does the same for accounts already adopted.

-- ---------------------------------------------------------------------------
-- pending_signups
--
-- Keyed by address, so a second attempt for the same mailbox replaces the first
-- rather than racing it. Not `app_users`: nothing here is an account yet.
--
-- The password is hashed on arrival even though the account may never exist. It
-- travels no further in plaintext than the request that carried it, and a leak of
-- this table must not hand over passwords people also used elsewhere.
-- ---------------------------------------------------------------------------

create table if not exists public.pending_signups (
  email         text   primary key,
  password_hash text   not null,
  display_name  text,
  timezone      text   not null default 'UTC',
  -- Hashed for the same reason as the password. A six-digit code is trivially
  -- brute-forced offline if this table ever leaks in plaintext.
  code_hash     text   not null,
  -- Capped rather than unlimited: six digits is a million guesses, which is
  -- nothing at all to a script and everything to a person typing.
  attempts      integer not null default 0,
  expires_at    bigint not null,
  -- When the last code went out, for the resend cooldown. Without it, the send
  -- button is an open relay pointed at somebody else's inbox.
  last_sent_at  bigint not null,
  created_at    bigint not null default public.epoch_ms()
);

-- No policies, deliberately. Every reader and writer below is SECURITY DEFINER;
-- the API's ordinary connection has no business reading a table of pending
-- credentials, and RLS with no policy denies it by default.
alter table public.pending_signups enable row level security;

-- Expired rows are dead weight and hold an address hostage against a fresh
-- attempt, since the primary key is the address.
create index if not exists pending_signups_expiry on public.pending_signups (expires_at);

-- ---------------------------------------------------------------------------
-- Request a code
--
-- Returns the row's expiry so the caller can tell the client how long it has,
-- rather than the two sides keeping separate copies of the same constant.
--
-- Raises `email-taken` for an address that already has an account. That is the
-- same refusal sign-up always gave, kept for the same reason: this function has
-- not yet verified anything, so it must not touch an existing account.
-- ---------------------------------------------------------------------------

create or replace function public.auth_request_signup_code(
  p_email text, p_password text, p_name text, p_timezone text,
  p_code text, p_ttl_seconds bigint, p_cooldown_seconds bigint
) returns bigint
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_now      bigint := public.epoch_ms();
  v_existing public.pending_signups;
  v_expires  bigint;
begin
  -- bcrypt silently ignores anything past 72 bytes, which would make two
  -- different long passwords interchangeable. Refuse rather than truncate.
  if length(p_password) < 8 or octet_length(p_password) > 72 then
    raise exception 'weak-password' using errcode = 'check_violation';
  end if;

  if exists (select 1 from public.app_users where lower(email) = lower(p_email)) then
    raise exception 'email-taken' using errcode = 'unique_violation';
  end if;

  select * into v_existing from public.pending_signups where email = lower(p_email);

  -- The cooldown is enforced here rather than in the API because this is the only
  -- place that knows when the last one actually went out. A caller looping the
  -- endpoint cannot outrun a row.
  if found and v_now < v_existing.last_sent_at + (p_cooldown_seconds * 1000) then
    raise exception 'resend-too-soon' using errcode = 'too_many_connections';
  end if;

  v_expires := v_now + (p_ttl_seconds * 1000);

  insert into public.pending_signups
    (email, password_hash, display_name, timezone, code_hash, attempts, expires_at, last_sent_at)
  values (
    lower(p_email),
    extensions.crypt(p_password, extensions.gen_salt('bf', 12)),
    p_name,
    coalesce(p_timezone, 'UTC'),
    extensions.crypt(p_code, extensions.gen_salt('bf', 10)),
    0,
    v_expires,
    v_now
  )
  on conflict (email) do update set
    password_hash = excluded.password_hash,
    display_name  = excluded.display_name,
    timezone      = excluded.timezone,
    code_hash     = excluded.code_hash,
    -- Reset, so a fresh code is not born halfway through the previous one's
    -- budget. Otherwise five wrong guesses would poison every later attempt.
    attempts      = 0,
    expires_at    = excluded.expires_at,
    last_sent_at  = excluded.last_sent_at;

  return v_expires;
end
$$;

-- ---------------------------------------------------------------------------
-- Verify a code, and only then create the account
--
-- The account and its password identity are written in this one transaction, so
-- there is never a moment where an unverified `app_users` row is visible to
-- anything — including a Google sign-in racing it.
--
-- Returns an outcome instead of raising, for the same reason
-- `auth_rotate_refresh_token` does: raising aborts the transaction, which would
-- roll back the very writes these failures depend on. A wrong code would not count
-- against the attempt budget and an expired row would not be cleared — the cap
-- would read as enforced while a script guessed a six-digit code at its leisure.
-- Nothing here is worth failing loudly enough to undo the record of the failure.
-- ---------------------------------------------------------------------------

drop function if exists public.auth_verify_signup_code(text, text);

create function public.auth_verify_signup_code(
  p_email text, p_code text
) returns table (
  outcome text, user_id uuid, email text, display_name text, timezone text
)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_now     bigint := public.epoch_ms();
  v_pending public.pending_signups;
  v_user    public.app_users;
begin
  select * into v_pending from public.pending_signups
   where public.pending_signups.email = lower(p_email)
     for update;

  -- One answer for "no such request" and "wrong code" alike, so the response
  -- cannot be used to learn which addresses have a sign-up in flight.
  if not found then
    return query select 'invalid-code'::text, null::uuid, null::text, null::text, null::text;
    return;
  end if;

  if v_pending.expires_at < v_now then
    delete from public.pending_signups where public.pending_signups.email = v_pending.email;
    return query select 'code-expired'::text, null::uuid, null::text, null::text, null::text;
    return;
  end if;

  -- Checked before the comparison, so a caller cannot buy extra guesses by
  -- racing several requests at the row.
  if v_pending.attempts >= 5 then
    delete from public.pending_signups where public.pending_signups.email = v_pending.email;
    return query select 'too-many-attempts'::text, null::uuid, null::text, null::text, null::text;
    return;
  end if;

  if v_pending.code_hash <> extensions.crypt(p_code, v_pending.code_hash) then
    update public.pending_signups set attempts = attempts + 1
     where public.pending_signups.email = v_pending.email;
    return query select 'invalid-code'::text, null::uuid, null::text, null::text, null::text;
    return;
  end if;

  -- Someone may have signed in with Google on this address while the code was in
  -- flight. Their account is real and verified; this request must not touch it.
  if exists (select 1 from public.app_users u where lower(u.email) = v_pending.email) then
    delete from public.pending_signups where public.pending_signups.email = v_pending.email;
    return query select 'email-taken'::text, null::uuid, null::text, null::text, null::text;
    return;
  end if;

  insert into public.app_users (email, email_verified, display_name, timezone, last_seen_at)
  values (v_pending.email, true, v_pending.display_name, v_pending.timezone, v_now)
  returning * into v_user;

  -- The hash is carried across as it was stored. The plaintext was never kept,
  -- and re-hashing here would need it.
  insert into public.user_identities (user_id, provider, subject, password_hash, last_used_at)
  values (v_user.id, 'password', v_pending.email, v_pending.password_hash, v_now);

  delete from public.pending_signups where public.pending_signups.email = v_pending.email;

  return query select 'created'::text, v_user.id, v_user.email, v_user.display_name, v_user.timezone;
end
$$;

-- ---------------------------------------------------------------------------
-- Housekeeping
--
-- Called opportunistically by the API rather than scheduled, because Supabase's
-- free plan has no cron and a table this small does not justify one.
-- ---------------------------------------------------------------------------

create or replace function public.auth_purge_expired_signups()
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_count integer;
begin
  delete from public.pending_signups where expires_at < public.epoch_ms();
  get diagnostics v_count = row_count;
  return v_count;
end
$$;

-- ---------------------------------------------------------------------------
-- Google adoption, hardened
--
-- Replaces the function wholesale rather than patching it, because the ordering
-- matters and is easy to get wrong: the row's `email_verified` must be read
-- *before* the update that sets it true, or the test always sees true and the
-- delete never fires.
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
  v_was_verified boolean;
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

  select * into v_user from public.app_users where lower(email) = lower(p_email);

  if not found then
    insert into public.app_users (email, email_verified, display_name, timezone, last_seen_at)
    values (p_email, true, p_name, coalesce(p_timezone, 'UTC'), v_now)
    returning * into v_user;
  else
    -- Read first. The update below sets it true unconditionally.
    v_was_verified := v_user.email_verified;

    update public.app_users set
      email_verified = true,
      display_name   = coalesce(display_name, p_name),
      updated_at     = v_now,
      last_seen_at   = v_now
     where id = v_user.id
     returning * into v_user;

    -- Adopting a row nobody ever verified. Whoever set its password did so
    -- without proving they own this mailbox, and Google has just told us the
    -- person signing in does own it. The password does not survive the handover.
    --
    -- A row that was already verified keeps its password: that is the ordinary
    -- case of someone who signed in with Google and added one from Settings.
    if not v_was_verified then
      delete from public.user_identities
       where user_id = v_user.id and provider = 'password';
    end if;
  end if;

  insert into public.user_identities (user_id, provider, subject, last_used_at)
  values (v_user.id, 'google', p_sub, v_now);

  return v_user;
end
$$;

-- ---------------------------------------------------------------------------
-- Sign-up by password is gone
--
-- Dropped rather than left in place raising an error. It is reachable only
-- through a grant, and a function that creates unverified accounts should not
-- exist to be granted again by mistake.
-- ---------------------------------------------------------------------------

drop function if exists public.auth_sign_up_with_password(text, text, text, text);

-- ---------------------------------------------------------------------------
-- Existing damage
--
-- Accounts already adopted through the old path still carry whatever password was
-- attached before the handover. The identities carry timestamps, so the ordering
-- distinguishes the two cases:
--
--   password created BEFORE google  →  the password predates the handover, and
--                                      nothing ever verified whoever set it
--   password created AFTER google   →  added from Settings by someone already
--                                      signed in, which is the safe route
--
-- Only the first is removed. Anyone affected can set a new password from Settings,
-- and the Google route they actually use is untouched.
-- ---------------------------------------------------------------------------

delete from public.user_identities pw
 where pw.provider = 'password'
   and exists (
     select 1 from public.user_identities g
      where g.user_id = pw.user_id
        and g.provider = 'google'
        and g.created_at > pw.created_at
   );

-- ---------------------------------------------------------------------------
-- Only these.
-- ---------------------------------------------------------------------------

revoke all on function public.auth_request_signup_code(text, text, text, text, text, bigint, bigint) from public;
revoke all on function public.auth_verify_signup_code(text, text) from public;
revoke all on function public.auth_purge_expired_signups() from public;
revoke all on function public.auth_sign_in_with_google(text, text, boolean, text, text) from public;

grant execute on function public.auth_request_signup_code(text, text, text, text, text, bigint, bigint) to deylee_api;
grant execute on function public.auth_verify_signup_code(text, text) to deylee_api;
grant execute on function public.auth_purge_expired_signups() to deylee_api;
grant execute on function public.auth_sign_in_with_google(text, text, boolean, text, text) to deylee_api;
