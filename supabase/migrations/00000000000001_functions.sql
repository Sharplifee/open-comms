-- Every function in the OpenComms database, captured byte-exact from live
-- project tbgcinfhgskcjoevfkea on 2026-09-04 with pg_get_functiondef.
--
-- These are the entire API. RLS is on for every table with no policies at
-- all, so the anon key cannot touch a row directly — it can only call these,
-- and each one is SECURITY DEFINER, which is what lets the server enforce a
-- rule rather than suggest one.
--
-- Two of them are the reason the app is not trivially abusable: join_squad
-- records every failure and consults join_backoff_seconds, which takes the
-- greater of a per-device and a per-IP-prefix backoff, and request_ip reads
-- the forwarded headers with inet_client_addr as the fallback. A three digit
-- code space is only a thousand wide, so the rate limit is load-bearing.
--
-- Regenerate with: select string_agg(pg_get_functiondef(p.oid), E';\n\n'
--   order by p.proname) from pg_proc p join pg_namespace n on
--   n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f';

CREATE OR REPLACE FUNCTION public.block_device(p_blocker text, p_blocked text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    insert into public.blocks (blocker_device, blocked_device, display_name)
    values (p_blocker, p_blocked,
            coalesce((select display_name from public.devices where device_id = p_blocked), 'Someone'))
    on conflict (blocker_device, blocked_device) do nothing;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.blocked_devices(p_blocker text)
 RETURNS TABLE(device_id text, display_name text, blocked_at timestamp with time zone)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select blocked_device, display_name, blocked_at
    from public.blocks where blocker_device = p_blocker
    order by blocked_at desc;
$function$
;

CREATE OR REPLACE FUNCTION public.claim_host(p_squad_id uuid, p_device_id text)
 RETURNS TABLE(r_host text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare current_host text; longest text;
begin
    select creator_device into current_host from public.squads where id = p_squad_id;

    if current_host is not null
       and exists (select 1 from public.squad_members
                   where squad_id = p_squad_id and device_id = current_host) then
        return query select current_host;
        return;
    end if;

    select device_id into longest from public.squad_members
    where squad_id = p_squad_id order by joined_at asc limit 1;

    update public.squads
    set creator_device = longest,
        expires_at = greatest(expires_at, now() + interval '2 hours')
    where id = p_squad_id;

    return query select longest;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_squad(p_code text, p_name text, p_device_id text DEFAULT NULL::text, p_display_name text DEFAULT 'Someone'::text)
 RETURNS TABLE(r_outcome text, r_squad_id uuid, r_squad_name text, r_join_code text, r_is_creator boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare created public.squads%rowtype;
begin
    if p_code !~ '^[0-9]{3}$' then
        return query select 'invalid'::text, null::uuid, null::text, null::text, false;
        return;
    end if;

    -- Dropping the caller into a stranger's open microphone is the one outcome
    -- that must never happen silently.
    if exists (select 1 from public.squads s
               where s.join_code = p_code and s.ended_at is null and s.expires_at > now()) then
        return query select 'taken'::text, null::uuid, null::text, null::text, false;
        return;
    end if;

    update public.squads set ended_at = now()
    where join_code = p_code and ended_at is null and expires_at <= now();

    insert into public.squads (name, join_code, creator_device)
    values (coalesce(nullif(p_name,''),'Squad'), p_code, p_device_id)
    returning * into created;

    if p_device_id is not null then
        insert into public.squad_members (squad_id, device_id, display_name)
        values (created.id, p_device_id, coalesce(nullif(p_display_name,''),'Someone'))
        on conflict (squad_id, device_id) do update set last_seen_at = now();
    end if;

    insert into public.join_attempts (code, device_id, succeeded, client_ip)
    values (p_code, p_device_id, true, public.request_ip());

    return query select 'ok'::text, created.id, created.name, created.join_code, true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.delete_device(p_device_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    delete from public.squad_members where device_id = p_device_id;
    delete from public.blocks where blocker_device = p_device_id or blocked_device = p_device_id;
    delete from public.devices where device_id = p_device_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.end_squad(p_squad_id uuid, p_device_id text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare affected integer;
begin
    update public.squads set ended_at = now(), expires_at = now()
    where id = p_squad_id and ended_at is null
      and (creator_device is null or creator_device = p_device_id);
    get diagnostics affected = row_count;
    return affected > 0;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.expire_squads()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    update public.squads set ended_at = now()
    where ended_at is null and expires_at <= now();
end;
$function$
;

CREATE OR REPLACE FUNCTION public.heartbeat(p_squad_id uuid, p_device_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    update public.squad_members set last_seen_at = now()
    where squad_id = p_squad_id and device_id = p_device_id;
    update public.devices set last_seen_at = now() where device_id = p_device_id;
    update public.squads set expires_at = greatest(expires_at, now() + interval '2 hours')
    where id = p_squad_id and ended_at is null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.ip_prefix(p inet)
 RETURNS inet
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select case when p is null then null
                when family(p) = 6 then network(set_masklen(p, 64))
                else network(set_masklen(p, 32)) end;
$function$
;

CREATE OR REPLACE FUNCTION public.join_backoff_seconds(p_device_id text)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select greatest(
        coalesce((select case when failures >= 10 then 60
                              when failures >=  5 then 10
                              else 0 end
                  from (select count(*) as failures from public.join_attempts a
                        where a.device_id = p_device_id and a.succeeded = false
                          and a.attempted_at > now() - interval '5 minutes') d), 0),
        coalesce((select case when failures >= 20 then 300
                              when failures >= 10 then 60
                              when failures >=  5 then 10
                              else 0 end
                  from (select count(*) as failures from public.join_attempts a
                        where a.client_ip is not null
                          and public.ip_prefix(a.client_ip) = public.ip_prefix(public.request_ip())
                          and a.succeeded = false
                          and a.attempted_at > now() - interval '5 minutes') i), 0)
    );
$function$
;

CREATE OR REPLACE FUNCTION public.join_squad(p_code text, p_device_id text DEFAULT NULL::text, p_display_name text DEFAULT 'Someone'::text)
 RETURNS TABLE(r_outcome text, r_retry_after integer, r_squad_id uuid, r_squad_name text, r_join_code text, r_is_creator boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    wait     integer := 0;
    existing public.squads%rowtype;
    members  integer;
    ip       inet := public.request_ip();
    already  boolean;
begin
    if p_code !~ '^[0-9]{3}$' then
        insert into public.join_attempts (code, device_id, succeeded, client_ip)
        values (p_code, p_device_id, false, ip);
        return query select 'invalid'::text, 0, null::uuid, null::text, null::text, false;
        return;
    end if;

    wait := public.join_backoff_seconds(p_device_id);
    if wait > 0 then
        return query select 'rate_limited'::text, wait, null::uuid, null::text, null::text, false;
        return;
    end if;

    select s.* into existing from public.squads s
    where s.join_code = p_code and s.ended_at is null;

    if not found then
        insert into public.join_attempts (code, device_id, succeeded, client_ip)
        values (p_code, p_device_id, false, ip);
        return query select 'not_found'::text, 0, null::uuid, null::text, null::text, false;
        return;
    end if;

    if existing.expires_at < now() then
        insert into public.join_attempts (code, device_id, succeeded, client_ip)
        values (p_code, p_device_id, false, ip);
        return query select 'expired'::text, 0, null::uuid, null::text, null::text, false;
        return;
    end if;

    -- Somebody already in the squad must ALWAYS get back in, even when it is
    -- full — otherwise a reconnect after a dropped connection locks a member
    -- out of the line they are standing in.
    already := exists (select 1 from public.squad_members m
                       where m.squad_id = existing.id and m.device_id = p_device_id);

    if not already then
        select count(*) into members from public.squad_members m where m.squad_id = existing.id;
        if members >= existing.max_members then
            insert into public.join_attempts (code, device_id, succeeded, client_ip)
            values (p_code, p_device_id, false, ip);
            return query select 'full'::text, 0, null::uuid, null::text, null::text, false;
            return;
        end if;
    end if;

    if p_device_id is not null then
        insert into public.squad_members (squad_id, device_id, display_name)
        values (existing.id, p_device_id, coalesce(nullif(p_display_name,''),'Someone'))
        on conflict (squad_id, device_id)
            do update set last_seen_at = now(), display_name = excluded.display_name;
    end if;

    -- A line in genuine use must not lapse mid-workout.
    update public.squads set expires_at = greatest(expires_at, now() + interval '2 hours')
    where id = existing.id;

    insert into public.join_attempts (code, device_id, succeeded, client_ip)
    values (p_code, p_device_id, true, ip);

    return query select 'ok'::text, 0, existing.id, existing.name, existing.join_code,
                        (existing.creator_device is not null and existing.creator_device = p_device_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.leave_squad(p_squad_id uuid, p_device_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare remaining integer;
begin
    delete from public.squad_members
    where squad_id = p_squad_id and device_id = p_device_id;

    select count(*) into remaining from public.squad_members where squad_id = p_squad_id;
    if remaining = 0 then
        update public.squads set ended_at = now(), expires_at = now()
        where id = p_squad_id and ended_at is null;
    end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.match_contacts(p_hashes text[])
 RETURNS TABLE(phone_hash text, display_name text, last_seen_at timestamp with time zone)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select d.phone_hash, d.display_name, d.last_seen_at
    from public.devices d
    where d.phone_hash = any(p_hashes)
      and d.phone_hash is not null
      and d.is_ghost_mode = false;
$function$
;

CREATE OR REPLACE FUNCTION public.prune_stale_members()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    delete from public.squad_members where last_seen_at < now() - interval '6 minutes';

    -- Only close a squad nobody has been on for a while. The previous rule
    -- could end a five-minute-old line the instant its members were pruned.
    update public.squads s set ended_at = now(), expires_at = now()
    where s.ended_at is null
      and not exists (select 1 from public.squad_members m where m.squad_id = s.id)
      and s.created_at < now() - interval '10 minutes';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.purge_stale_locations()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    update public.devices
    set latitude = null, longitude = null, location_updated_at = null
    where location_updated_at is not null
      and location_updated_at < now() - interval '15 minutes';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.register_device(p_device_id text, p_display_name text, p_phone_hash text DEFAULT NULL::text, p_ghost boolean DEFAULT false, p_identity text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    insert into public.devices (device_id, display_name, phone_hash, is_ghost_mode,
                                livekit_identity, last_seen_at)
    values (p_device_id, coalesce(nullif(p_display_name,''),'Someone'),
            p_phone_hash, p_ghost, p_identity, now())
    on conflict (device_id) do update
        set display_name     = excluded.display_name,
            phone_hash       = coalesce(excluded.phone_hash, devices.phone_hash),
            is_ghost_mode    = excluded.is_ghost_mode,
            livekit_identity = coalesce(excluded.livekit_identity, devices.livekit_identity),
            last_seen_at     = now();
end;
$function$
;

CREATE OR REPLACE FUNCTION public.report_device(p_reporter text, p_reported text, p_squad uuid, p_reason text, p_detail text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    insert into public.reports (reporter_device, reported_device, squad_id, reason, detail)
    values (p_reporter, p_reported, p_squad, p_reason, p_detail);
    perform public.block_device(p_reporter, p_reported);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.request_ip()
 RETURNS inet
 LANGUAGE plpgsql
 STABLE
AS $function$
declare hdrs json; fwd text;
begin
    begin
        hdrs := current_setting('request.headers', true)::json;
    exception when others then
        return inet_client_addr();
    end;
    if hdrs is null then return inet_client_addr(); end if;
    fwd := coalesce(hdrs->>'cf-connecting-ip', split_part(hdrs->>'x-forwarded-for', ',', 1));
    if fwd is null or btrim(fwd) = '' then return inet_client_addr(); end if;
    begin
        return btrim(fwd)::inet;
    exception when others then
        return inet_client_addr();
    end;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_ghost_mode(p_device_id text, p_ghost boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    update public.devices
    set is_ghost_mode = p_ghost,
        latitude  = case when p_ghost then null else latitude end,
        longitude = case when p_ghost then null else longitude end,
        location_updated_at = case when p_ghost then null else location_updated_at end
    where device_id = p_device_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.trim_join_attempts()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    delete from public.join_attempts where attempted_at < now() - interval '7 days';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.unblock_device(p_blocker text, p_blocked text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    delete from public.blocks
    where blocker_device = p_blocker and blocked_device = p_blocked;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_location(p_device_id text, p_lat double precision, p_lon double precision)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    update public.devices
    set latitude = p_lat, longitude = p_lon,
        location_updated_at = now(), last_seen_at = now()
    where device_id = p_device_id and is_ghost_mode = false;
end;
$function$
;
-- ---------------------------------------------------------------- schedule
-- pg_cron jobs as they run live. Recreate with cron.schedule if the project
-- is ever rebuilt; without them nothing ever expires and codes leak.
--   */2 * * * *  select public.prune_stale_members()
--   */5 * * * *  select public.expire_squads()
--   */5 * * * *  select public.purge_stale_locations()
--   17  4 * * *  select public.trim_join_attempts()
