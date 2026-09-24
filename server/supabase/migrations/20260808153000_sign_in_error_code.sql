-- A rejected password must not carry SQLSTATE class 28.
--
-- The previous definition raised 'invalid-credentials' using errcode
-- 'invalid_password' — 28P01, chosen because it read like the truthful name for a
-- wrong password. But class 28 is the class Postgres itself uses when a
-- *connection's* login fails, and client libraries take it at its word:
-- PostgresNIO closes the whole pooled connection on any 28xxx error
-- (ConnectionStateMachine.shouldCloseConnection). Every failed sign-in therefore
-- destroyed a healthy connection mid-transaction, and the API's ROLLBACK, racing
-- the teardown, would sometimes wait forever on a connection that no longer
-- existed — a sign-in attempt that simply never answered.
--
-- RAISE's default, P0001, says what is actually true: a stored procedure rejected
-- the request. The API matches on the message text, never the code, so nothing
-- else changes shape.
--
-- Everything else in this schema already raises outside class 28 (23xxx, 53300,
-- P0002) and needs no correction. This is also a rule going forward: no function
-- an API calls may raise class 28, whatever the name reads like.

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
    raise exception 'invalid-credentials';
  end if;

  update public.user_identities set last_used_at = v_now
   where user_id = v_user.id and provider = 'password';
  update public.app_users set last_seen_at = v_now where id = v_user.id
   returning * into v_user;

  return v_user;
end
$$;
