-- Deylee — make row-level security bind to the owner too.
--
-- `enable row level security` exempts the table's owner. That is fine while the API
-- connects as `deylee_api`, which owns nothing — but it makes tenancy depend on a
-- fact nothing in the repository states or checks. A migration run that leaves
-- `deylee_api` owning these tables turns every policy off, silently, with no error
-- and no change in behaviour until one customer reads another's hours.
--
-- `force` removes the exemption: the policies apply to the owner as well, and the
-- only role that can still bypass them is a superuser or one with BYPASSRLS. The API
-- now refuses to start as either, so both routes are closed.

alter table public.days     force row level security;
alter table public.segments force row level security;
alter table public.app_users force row level security;
