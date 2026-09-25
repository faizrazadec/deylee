-- Feedback: what somebody typed and pressed send on, and nothing else.
--
-- This is the one table in the schema that holds prose the user wrote, so it is
-- worth being explicit about what it is not. It is not telemetry. Nothing writes
-- here unless a person opened the window, typed, and chose to send; there is no
-- automatic report, no crash payload, no attached log, no screenshot. The app
-- version and OS string travel because a bug report without them is usually
-- unactionable, and they are the same two facts the About window already shows.
--
-- Tied to an account on purpose. Anonymous feedback cannot be replied to, cannot
-- be rate limited honestly, and is the easiest table in any product to fill with
-- rubbish. Requiring a session makes every row answerable to somebody.
--
-- Append-only by construction, exactly like audit_marks and witness_beats: the
-- API role gets no table grant at all. The only way in is the SECURITY DEFINER
-- function below, which takes the author from the transaction's tenancy variable
-- rather than from anything the client says, so a stolen token cannot file
-- feedback in another account's name.

create table if not exists public.feedback (
  id          bigint generated always as identity primary key,
  user_id     uuid   not null references public.app_users(id) on delete cascade,
  body        text   not null,
  -- Which build and which macOS, so a report can be reproduced against the right
  -- one. Nullable: an older client that does not send them is not an error.
  app_version text,
  os_version  text,
  -- The server's clock. The client's opinion of the time is not interesting here
  -- and accepting it would only be another thing to validate.
  sent_at     bigint not null default public.epoch_ms(),
  constraint feedback_body_not_blank check (length(btrim(body)) > 0),
  constraint feedback_body_bounded   check (length(body) <= 4000)
);

create index if not exists feedback_by_user_time
  on public.feedback (user_id, sent_at desc);

alter table public.feedback enable row level security;
alter table public.feedback force row level security;

-- File one piece of feedback for the signed-in user.
--
-- Returns false rather than raising when the sender is over the hourly limit, so
-- the endpoint can answer "slow down" without the caller learning anything about
-- other rows. Five an hour is generous for a person and tedious for a script.
--
-- The body is trimmed and length-checked here as well as in the constraints,
-- because a constraint violation reaches the client as a 500 and a clear refusal
-- reaches it as itself.
create or replace function public.submit_feedback(
  p_body        text,
  p_app_version text,
  p_os_version  text
) returns boolean
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user uuid := public.current_app_user();
  v_body text := btrim(coalesce(p_body, ''));
  v_now  bigint := public.epoch_ms();
begin
  if v_user is null then
    raise exception 'no-tenant' using errcode = 'check_violation';
  end if;
  if length(v_body) = 0 then
    raise exception 'empty-feedback' using errcode = 'check_violation';
  end if;
  if length(v_body) > 4000 then
    raise exception 'feedback-too-long' using errcode = 'check_violation';
  end if;

  if (
    select count(*) from public.feedback
     where user_id = v_user and sent_at > v_now - 3600000
  ) >= 5 then
    return false;
  end if;

  insert into public.feedback (user_id, body, app_version, os_version, sent_at)
  values (v_user, v_body, left(p_app_version, 64), left(p_os_version, 128), v_now);
  return true;
end
$$;

revoke all on function public.submit_feedback(text, text, text) from public;
grant execute on function public.submit_feedback(text, text, text) to deylee_api;
