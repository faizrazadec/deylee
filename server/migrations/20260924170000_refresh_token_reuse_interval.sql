-- Deylee — a reuse interval for refresh tokens.
--
-- `auth_rotate_refresh_token` reads any second use of a replaced token as theft and
-- revokes the whole chain. That is right for a token that surfaces an hour later from
-- somewhere else, and wrong for one presented twice within the same second by the same
-- client — two requests racing on a wake, or an app killed between receiving the rotated
-- pair and writing it to the Keychain. Both of those signed a real person out, and the
-- server could not tell them apart from an attack because it never tried.
--
-- Supabase's auth server has the same rule and the same exception:
-- SECURITY_REFRESH_TOKEN_REUSE_INTERVAL, ten seconds by default. Inside the window, the
-- token that was *just* replaced may be exchanged again. Outside it, or for any token
-- older than that, replay detection is exactly as strict as before.
--
-- One difference, forced by storage. Supabase answers a reuse with the same successor it
-- already issued; this table holds only digests, so the successor's plaintext is gone and
-- a sibling on the same session is issued instead. The session id is unchanged, so every
-- revocation of that session still reaches both.

-- The argument list changes, so the old signature has to go rather than be replaced.
drop function if exists public.auth_rotate_refresh_token(bytea, bytea, bigint);

-- The interval defaults to zero, which is the old behaviour exactly. That keeps the
-- deploy order free: an API still sending three arguments resolves to this function and
-- keeps its strict rule until the new API, which passes its configured interval, is up.
create function public.auth_rotate_refresh_token(
  p_old_hash bytea, p_new_hash bytea, p_expires_at bigint, p_reuse_interval_ms bigint default 0
) returns table (outcome text, user_id uuid, email text, display_name text, timezone text)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_token       public.refresh_tokens;
  v_replacement public.refresh_tokens;
  v_user        public.app_users;
  v_new         uuid;
  v_now         bigint := public.epoch_ms();
begin
  -- Locked, so two exchanges of one token queue here instead of both reading it as never
  -- replaced. Without the lock the race this migration is about skipped the replay check
  -- entirely and forked the chain by accident; with it, the second request sees the
  -- first one's successor and is judged against the window.
  select * into v_token from public.refresh_tokens
   where token_hash = p_old_hash
     for update;
  if not found then
    return query select 'unknown'::text, null::uuid, null::text, null::text, null::text;
    return;
  end if;

  if v_token.revoked_at is not null or v_token.replaced_by is not null then
    select * into v_replacement from public.refresh_tokens where id = v_token.replaced_by;

    -- Forgiven only when all of it holds: nothing on the session has been revoked, this
    -- token's successor is itself still unused — so this is the immediately previous
    -- token, not one from further up the chain — and that successor is younger than the
    -- window. Anything else is the replay it always was.
    if not (
      v_token.revoked_at is null
      and v_replacement.id is not null
      and v_replacement.revoked_at is null
      and v_replacement.replaced_by is null
      and v_now - v_replacement.issued_at <= p_reuse_interval_ms
    ) then
      update public.refresh_tokens set revoked_at = v_now
       where session_id = v_token.session_id and revoked_at is null;
      return query select 'replayed'::text, null::uuid, null::text, null::text, null::text;
      return;
    end if;
  end if;

  if v_token.expires_at <= v_now then
    return query select 'expired'::text, null::uuid, null::text, null::text, null::text;
    return;
  end if;

  insert into public.refresh_tokens (user_id, session_id, token_hash, device_id, expires_at)
  values (v_token.user_id, v_token.session_id, p_new_hash, v_token.device_id, p_expires_at)
  returning id into v_new;

  -- A forgiven reuse leaves `replaced_by` on the first successor. Moving it to the
  -- sibling would make the first one look unused and reopen the window for as long as
  -- the client keeps racing.
  if v_token.replaced_by is null then
    update public.refresh_tokens set replaced_by = v_new where id = v_token.id;
  end if;

  select * into v_user from public.app_users where id = v_token.user_id;
  return query select 'rotated'::text, v_user.id, v_user.email, v_user.display_name, v_user.timezone;
end
$$;

revoke all on function public.auth_rotate_refresh_token(bytea, bytea, bigint, bigint) from public;
grant execute on function public.auth_rotate_refresh_token(bytea, bytea, bigint, bigint) to deylee_api;
