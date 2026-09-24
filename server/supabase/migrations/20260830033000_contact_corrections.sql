-- Contact requests: a third route, for "something is wrong".
--
-- The form grew a correction route beside the Teams waitlist and the Enterprise enquiry:
-- a bug, a claim on the site that does not hold, a number that looks wrong. It is the
-- most useful mail a pre-release product gets and it had nowhere to go except an inbox
-- on another domain.
--
-- A separate migration rather than an edit to the one that created the table, even though
-- that one is days old and may not have been applied yet. Editing an applied migration is
-- silent: `supabase db push` skips a file it has already run, so production keeps the old
-- constraint while the repository says otherwise, and the first correction anybody sends
-- fails on a check nobody can see. Append-only costs a few lines and cannot do that.

alter table public.contact_requests
  drop constraint if exists contact_requests_kind_known;

alter table public.contact_requests
  add constraint contact_requests_kind_known
  check (kind in ('teams', 'enterprise', 'fix'));

-- Replaced whole rather than patched, because the body is the readable statement of what
-- the table accepts and a reader should not have to diff two migrations to know it.
--
-- What changes: 'fix' joins the accepted kinds, and the message is kept for it as well as
-- for Enterprise. The headcount stays Enterprise-only — a correction has no team size, and
-- storing one because the field happened to be posted is how a table ends up holding
-- things the form never asked for.
create or replace function public.submit_contact_request(
  p_kind      text,
  p_email     text,
  p_team_size text,
  p_message   text
) returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_kind    text   := btrim(coalesce(p_kind, ''));
  v_email   text   := lower(btrim(coalesce(p_email, '')));
  v_message text   := nullif(btrim(coalesce(p_message, '')), '');
  v_now     bigint := public.epoch_ms();
begin
  if v_kind not in ('teams', 'enterprise', 'fix') then
    raise exception 'unknown-kind' using errcode = 'check_violation';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or length(v_email) > 320 then
    raise exception 'bad-email' using errcode = 'check_violation';
  end if;
  if length(coalesce(v_message, '')) > 4000 then
    raise exception 'message-too-long' using errcode = 'check_violation';
  end if;

  -- Per address, not per row: three in an hour is more than anybody has to say and few
  -- enough that a script pointed at one mailbox stops being useful. Somebody with a fourth
  -- bug inside the hour has Settings -> Send feedback, which the form says so out loud.
  if (
    select count(*) from public.contact_requests
     where email = v_email and created_at > v_now - 3600000
  ) >= 3 then
    return false;
  end if;

  insert into public.contact_requests (kind, email, team_size, message, created_at)
  values (
    v_kind,
    v_email,
    case when v_kind = 'enterprise' then left(btrim(p_team_size), 32) end,
    case when v_kind in ('enterprise', 'fix') then v_message end,
    v_now
  )
  -- Only reachable on the teams route, where the partial unique index makes a repeat
  -- submission a no-op. A correction is never a duplicate: two reports from one address
  -- are two things somebody noticed.
  on conflict do nothing;

  return true;
end
$$;

revoke all on function public.submit_contact_request(text, text, text, text) from public;
grant execute on function public.submit_contact_request(text, text, text, text) to deylee_api;
