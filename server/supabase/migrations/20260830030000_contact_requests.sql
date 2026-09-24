-- Contact requests: the Teams waitlist and the Enterprise enquiry, from the site.
--
-- The one unauthenticated write in the schema, and the only table here whose rows a
-- stranger can create. That is not an oversight — a waitlist you must already have an
-- account to join is not a waitlist — but it is the reason everything below is stricter
-- than the authenticated tables need to be.
--
-- What it holds is what the form asks for and nothing more: which of the two routes was
-- used, the address to reply to, and on the Enterprise route a headcount band and what
-- the sender is trying to solve. No IP address, no user agent, no referrer, no campaign
-- parameter. The site's whole argument is that only what you typed leaves your machine,
-- and a marketing table quietly holding the rest would make that false on the one page
-- that asks strangers to trust it.
--
-- Append-only by construction, exactly like feedback, audit_marks and witness_beats: the
-- API role gets no table grant at all, and the only way in is the SECURITY DEFINER
-- function below.

create table if not exists public.contact_requests (
  id         bigint generated always as identity primary key,
  -- Which side of the form. Constrained rather than free text, because the two are read
  -- differently — one is a list to write to once, the other is a conversation.
  kind       text   not null,
  email      text   not null,
  -- Enterprise only, and both nullable for that reason. A band rather than a number: the
  -- form offers four, and a free integer would invite a validation argument for a value
  -- nobody acts on precisely.
  team_size  text,
  message    text,
  -- The server's clock. The sender's opinion of the time is not interesting and accepting
  -- it would only be another thing to validate.
  created_at bigint not null default public.epoch_ms(),
  constraint contact_requests_kind_known
    check (kind in ('teams', 'enterprise')),
  constraint contact_requests_email_shaped
    check (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  constraint contact_requests_email_bounded
    check (length(email) <= 320),
  constraint contact_requests_team_size_bounded
    check (team_size is null or length(team_size) <= 32),
  constraint contact_requests_message_bounded
    check (message is null or length(message) <= 4000)
);

-- Pressing "Put me on the list" twice leaves you on the list once. Partial, because the
-- same idempotency would be wrong for Enterprise: a second enquiry from an address that
-- already wrote is a second thing somebody wants to say, not a duplicate.
create unique index if not exists contact_requests_one_waitlist_entry
  on public.contact_requests (email) where kind = 'teams';

create index if not exists contact_requests_by_time
  on public.contact_requests (created_at desc);

alter table public.contact_requests enable row level security;
alter table public.contact_requests force row level security;

-- Record one contact request.
--
-- Returns false rather than raising when the address is over its hourly allowance, so the
-- endpoint can answer "slow down" without the caller learning anything about other rows —
-- including whether the address is already on the list.
--
-- Refuses, loudly, for anything malformed. The route checks the same things first; both
-- do it because a constraint violation reaches the client as a 500 and a named refusal
-- reaches it as itself, and because this function is the only door and must hold the line
-- whatever calls it.
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
  if v_kind not in ('teams', 'enterprise') then
    raise exception 'unknown-kind' using errcode = 'check_violation';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or length(v_email) > 320 then
    raise exception 'bad-email' using errcode = 'check_violation';
  end if;
  if length(coalesce(v_message, '')) > 4000 then
    raise exception 'message-too-long' using errcode = 'check_violation';
  end if;

  -- Per address, not per row: three in an hour is more than anybody has to say and few
  -- enough that a script pointed at one mailbox stops being useful. The IP ceiling in
  -- front of this is what bounds a script cycling through addresses instead.
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
    case when v_kind = 'enterprise' then v_message end,
    v_now
  )
  -- Only reachable on the teams route, where the partial index above makes a repeat
  -- submission a no-op. Answered as success: the person asked to be on the list, and
  -- they are.
  on conflict do nothing;

  return true;
end
$$;

revoke all on function public.submit_contact_request(text, text, text, text) from public;
grant execute on function public.submit_contact_request(text, text, text, text) to deylee_api;
