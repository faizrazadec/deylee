-- Revoking every session but this one
--
-- `auth_revoke_session` has existed since password auth landed and nothing ever
-- called it. Sign-out now does, but sign-out is not the moment that matters most.
-- Changing a password is: people do it *because* they think somebody else has their
-- account, and until now it left every session that somebody had opened running for
-- the full ninety days of a refresh chain.
--
-- The caller's own session is kept. Signing yourself out of the device you are
-- holding is not what "change my password" means, and doing it would train people
-- out of the habit.
--
-- Returning the session ids is not decoration. The API refuses revoked ids in memory
-- for the remaining life of an access token, and it can only do that for ids it has
-- been told about — without this the access tokens on the other devices would go on
-- working for their last hour.

create or replace function public.auth_revoke_other_sessions(
  p_user_id uuid, p_keep_session_id uuid
) returns setof uuid
  language sql
  security definer
  set search_path = ''
as $$
  with revoked as (
    update public.refresh_tokens set revoked_at = public.epoch_ms()
     where user_id = p_user_id
       and revoked_at is null
       and session_id is distinct from p_keep_session_id
    returning session_id
  )
  -- A session holds one live token at a time, but a chain rotated mid-flight can
  -- briefly hold two. Distinct, so the caller gets sessions rather than rows.
  select distinct session_id from revoked;
$$;

revoke all on function public.auth_revoke_other_sessions(uuid, uuid) from public;
grant execute on function public.auth_revoke_other_sessions(uuid, uuid) to deylee_api;
