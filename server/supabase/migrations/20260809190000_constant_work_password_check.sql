-- Deylee — spend the same work on an address that does not exist.
--
-- The old query joined the identity and the hash comparison into one statement:
--
--     where i.subject = lower(p_email)
--       and i.password_hash = extensions.crypt(p_password, i.password_hash)
--
-- With no matching identity the join produces no row and `crypt` never runs. With one,
-- it runs at bcrypt cost 12 — around 250 ms, deliberately. Both answers are the same
-- sentence, and the migration, the API's error mapping and `smoke-auth.sh` all say so
-- and all check it. The bodies match. The clock did not, and nothing checked the clock:
-- a hundred-millisecond gap on a single request, readable across the internet without
-- averaging, which enumerates who has an account.
--
-- The lookup and the comparison are separated now, and the comparison always happens.
-- When no identity is found it runs against a fixed hash of the same cost, so the work
-- is spent either way.
--
-- This makes every attempt cost a quarter-second of database CPU whether or not the
-- address exists, which is precisely the weapon #11 describes — an unauthenticated
-- request turned into 250 ms of Postgres. It is only safe alongside the rate limiting
-- landing with it. Neither half is complete on its own.

create or replace function public.auth_sign_in_with_password(
  p_email text, p_password text
) returns public.app_users
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user     public.app_users;
  v_now      bigint := public.epoch_ms();
  v_hash     text;
  v_user_id  uuid;
  v_matches  boolean;
  -- bcrypt of a value nobody can present, at the same cost as a real one. Fixed rather
  -- than generated per call: `gen_salt` plus a hash would double the work for unknown
  -- addresses and invert the very timing signal this removes.
  --
  -- Cost 12, matching `auth_set_password` and the sign-up path. Changing the cost
  -- there without changing it here re-opens the channel, quietly.
  c_absent constant text :=
    '$2a$12$C6UzMDM.H6dfI/f/IKcEeO3Qm3aBrMPQKvJTiuAOEMdb0hnRe5ate';
begin
  -- Lookup by address alone. No hashing here, so this costs the same whether or not
  -- the address is known.
  select i.user_id, i.password_hash into v_user_id, v_hash
    from public.user_identities i
   where i.provider = 'password' and i.subject = lower(p_email);

  if v_hash is null then
    v_hash := c_absent;
  end if;

  -- Always. This is the expensive statement and it runs on every call.
  v_matches := (v_hash = extensions.crypt(p_password, v_hash));

  -- `v_user_id is null` is folded in rather than returned early above, so an unknown
  -- address and a wrong password leave by the same path.
  if not v_matches or v_user_id is null then
    raise exception 'invalid-credentials';
  end if;

  select * into v_user from public.app_users u where u.id = v_user_id;
  if not found then
    raise exception 'invalid-credentials';
  end if;

  update public.user_identities set last_used_at = v_now
   where user_id = v_user.id and provider = 'password';
  update public.app_users set last_seen_at = v_now where id = v_user.id
   returning * into v_user;

  return v_user;
end
$$;

revoke all on function public.auth_sign_in_with_password(text, text) from public;
grant execute on function public.auth_sign_in_with_password(text, text) to deylee_api;
