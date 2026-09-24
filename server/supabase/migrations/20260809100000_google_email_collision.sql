-- Deylee — name the collision when a Google address is already registered here.
--
-- `auth_sign_in_with_google` overwrites the stored address with whatever Google now
-- reports, because people do change it and the account should follow. But
-- `app_users_one_per_email` is unique on `lower(email)`, so changing your Google
-- address to one that already belongs to a *different* Deylee account made that
-- update raise a bare
--
--     23505 duplicate key value violates unique constraint "app_users_one_per_email"
--
-- The API matches refusals on their message text, and that text is Postgres's, not
-- ours. It matched nothing, fell through to the generic branch, and became
--
--     500 The request could not be completed.
--
-- on a sign-in that had already succeeded at Google. Nothing was broken — the account
-- was intact and its password still worked — but Continue with Google failed from
-- then on, permanently, with an error nobody could act on and no log line behind it.
--
-- Refused rather than merged, deliberately. Two accounts hold two sets of hours and
-- two sync cursors, and choosing which survives is a product decision. It does not
-- belong inside a sign-in, made implicitly, on a person's whole history.

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
    -- Handled where the write happens rather than by asking first. A check before
    -- the update would still lose a race with another sign-in claiming the same
    -- address in the gap, and would then raise the very error it was added to
    -- prevent. The only constraint this statement can violate is the one on the
    -- address, so catching it here is precise rather than a catch-all.
    begin
      update public.app_users set
        email        = p_email,
        display_name = coalesce(p_name, display_name),
        timezone     = coalesce(p_timezone, timezone),
        updated_at   = v_now,
        last_seen_at = v_now
       where id = v_user.id
       returning * into v_user;
    exception when unique_violation then
      raise exception 'email-collision' using errcode = 'unique_violation';
    end;

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
-- The same race, one function over
--
-- `auth_verify_signup_code` checks for an existing account and then inserts one.
-- A Google sign-in landing on that address between the two statements produced the
-- identical bare 23505, and this function is reached by a route that reports
-- outcomes rather than exceptions — so the raw error escaped as a 500 while every
-- deliberate refusal beside it answered cleanly.
-- ---------------------------------------------------------------------------

create or replace function public.auth_verify_signup_code(
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

  begin
    insert into public.app_users (email, email_verified, display_name, timezone, last_seen_at)
    values (v_pending.email, true, v_pending.display_name, v_pending.timezone, v_now)
    returning * into v_user;
  exception when unique_violation then
    -- Lost the race described above. The same answer the check gives, because from
    -- here the two are the same fact arriving a moment apart.
    delete from public.pending_signups where public.pending_signups.email = v_pending.email;
    return query select 'email-taken'::text, null::uuid, null::text, null::text, null::text;
    return;
  end;

  -- The hash is carried across as it was stored. The plaintext was never kept,
  -- and re-hashing here would need it.
  insert into public.user_identities (user_id, provider, subject, password_hash, last_used_at)
  values (v_user.id, 'password', v_pending.email, v_pending.password_hash, v_now);

  delete from public.pending_signups where public.pending_signups.email = v_pending.email;

  return query select 'created'::text, v_user.id, v_user.email, v_user.display_name, v_user.timezone;
end
$$;

-- `create or replace` keeps the existing grants, but naming them is cheap and makes
-- a mistake here loud rather than a permission failure at the first sign-in.
revoke all on function public.auth_sign_in_with_google(text, text, boolean, text, text) from public;
revoke all on function public.auth_verify_signup_code(text, text) from public;

grant execute on function public.auth_sign_in_with_google(text, text, boolean, text, text) to deylee_api;
grant execute on function public.auth_verify_signup_code(text, text) to deylee_api;
