-- Applied live to tbgcinfhgskcjoevfkea 2026-09-09 and proved end to end:
-- a public line was listed to a stranger, the stranger asked, the host saw the
-- request by name, the host said yes, and the poll returned the join code.
--
-- 1. THE CAP IS GONE. max_members defaulted to 8 and join_squad refused past
--    it. There was never a reason for the number — LiveKit bills by
--    participant-minute and does not care — and "your line is full" is an
--    insulting thing to tell somebody who invited one person too many.
--    Existing rows are lifted too, because a cap somebody is already stuck
--    behind is the one that matters.
--
-- 2. PUBLIC LINES. Every line was unlisted: you could only join a code
--    somebody handed you. Right for two people in a gym, wrong for a club
--    session or a coaching group. A public line is listed to people nearby.
--
-- 3. KNOCKING. Joining a public line ASKS rather than enters. The host sees
--    who is asking and says yes or no — the difference between a line anybody
--    can find and a line anybody can walk into. A block in either direction
--    hides the line entirely rather than letting somebody ask and be refused.

alter table public.squads alter column max_members set default 2147483647;
update public.squads set max_members = 2147483647 where max_members < 2147483647;

alter table public.squads add column if not exists is_public boolean not null default false;
create index if not exists squads_public_live on public.squads (created_at desc)
    where is_public and ended_at is null;

create table if not exists public.join_requests (
    squad_id     uuid        not null references public.squads(id) on delete cascade,
    device_id    text        not null,
    display_name text        not null default 'Someone',
    asked_at     timestamptz not null default now(),
    -- null = still waiting, true = let in, false = turned away
    granted      boolean,
    primary key (squad_id, device_id)
);
alter table public.join_requests enable row level security;
create index if not exists join_requests_pending on public.join_requests (squad_id, asked_at)
    where granted is null;

CREATE OR REPLACE FUNCTION public.answer_request(p_squad_id uuid, p_host_device text, p_device_id text, p_grant boolean)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    code text;
begin
    select s.join_code into code from public.squads s
    where s.id = p_squad_id and s.creator_device = p_host_device and s.ended_at is null;
    if code is null then return 'not_found'; end if;

    update public.join_requests set granted = p_grant
    where squad_id = p_squad_id and device_id = p_device_id;

    return case when p_grant then code else 'denied' end;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.ask_to_join(p_squad_id uuid, p_device_id text, p_display_name text DEFAULT 'Someone'::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    wait integer;
begin
    wait := public.join_backoff_seconds(p_device_id);
    if wait > 0 then return 'rate_limited'; end if;

    if not exists (select 1 from public.squads s
                   where s.id = p_squad_id and s.is_public and s.ended_at is null) then
        return 'not_found';
    end if;

    insert into public.join_requests (squad_id, device_id, display_name)
    values (p_squad_id, p_device_id, coalesce(nullif(p_display_name, ''), 'Someone'))
    on conflict (squad_id, device_id)
        do update set asked_at = now(), granted = null, display_name = excluded.display_name;

    return 'asked';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pending_requests(p_squad_id uuid, p_device_id text)
 RETURNS TABLE(device_id text, display_name text, asked_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select r.device_id, r.display_name, r.asked_at
    from public.join_requests r
    join public.squads s on s.id = r.squad_id
    where r.squad_id = p_squad_id
      and r.granted is null
      -- Only the host is shown the queue.
      and s.creator_device = p_device_id
    order by r.asked_at;
$function$
;

CREATE OR REPLACE FUNCTION public.public_lines(p_device_id text, p_lat double precision DEFAULT NULL::double precision, p_lon double precision DEFAULT NULL::double precision)
 RETURNS TABLE(squad_id uuid, squad_name text, host_name text, members integer, metres double precision, already_in boolean, asked boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select s.id,
           s.name,
           coalesce(d.display_name, 'Someone'),
           (select count(*)::int from public.squad_members m where m.squad_id = s.id),
           case
               when p_lat is null or d.latitude is null then null
               else 6371000 * 2 * asin(sqrt(
                   power(sin((radians(d.latitude) - radians(p_lat)) / 2), 2)
                 + cos(radians(p_lat)) * cos(radians(d.latitude))
                 * power(sin((radians(d.longitude) - radians(p_lon)) / 2), 2)))
           end,
           exists (select 1 from public.squad_members m
                   where m.squad_id = s.id and m.device_id = p_device_id),
           exists (select 1 from public.join_requests r
                   where r.squad_id = s.id and r.device_id = p_device_id and r.granted is null)
    from public.squads s
    left join public.devices d on d.device_id = s.creator_device
    where s.is_public
      and s.ended_at is null
      and s.expires_at > now()
      -- A block in either direction hides the line entirely, rather than
      -- letting somebody ask and be refused.
      and not exists (
          select 1 from public.squad_members m
          join public.blocks b
            on (b.blocker_device = p_device_id and b.blocked_device = m.device_id)
            or (b.blocker_device = m.device_id and b.blocked_device = p_device_id)
          where m.squad_id = s.id)
    order by 5 nulls last, s.created_at desc
    limit 25;
$function$
;

CREATE OR REPLACE FUNCTION public.request_answer(p_squad_id uuid, p_device_id text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select case
             when r.granted is null then 'waiting'
             when r.granted then (select s.join_code from public.squads s where s.id = r.squad_id)
             else 'denied'
           end
    from public.join_requests r
    where r.squad_id = p_squad_id and r.device_id = p_device_id;
$function$
;

CREATE OR REPLACE FUNCTION public.set_line_public(p_squad_id uuid, p_device_id text, p_public boolean)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    update public.squads
    set is_public = p_public
    where id = p_squad_id and creator_device = p_device_id and ended_at is null;
$function$
;
grant execute on function public.public_lines(text, double precision, double precision) to anon;
grant execute on function public.ask_to_join(uuid, text, text) to anon;
grant execute on function public.pending_requests(uuid, text) to anon;
grant execute on function public.answer_request(uuid, text, text, boolean) to anon;
grant execute on function public.request_answer(uuid, text) to anon;
grant execute on function public.set_line_public(uuid, text, boolean) to anon;
