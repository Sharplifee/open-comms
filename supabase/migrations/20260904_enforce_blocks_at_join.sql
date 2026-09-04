-- Blocking was local to one session. You could block somebody mid-line, leave,
-- rejoin the same code, and hear them again at full volume — and nothing on
-- the server ever knew. Reporting auto-blocks, so this applied to reports too:
-- the one control that exists for "I do not want to hear this person" lasted
-- until the app was closed.
--
-- The block is now checked where it can actually be enforced, at the door.
-- Either direction counts: if you blocked them you must not have to hear them,
-- and if they blocked you it is not your place to walk back into their line.
--
-- Somebody ALREADY on the line is exempt, deliberately. The exemption is what
-- lets a member reconnect after a dropped connection, and applying a block
-- retroactively would eject a person mid-conversation on the strength of a tap
-- somebody else just made. New arrivals are where a block belongs.
--
-- Returns the new outcome 'blocked', which the client renders as "You can't
-- join that line" — vague on purpose. Naming the person would tell a blocked
-- stranger exactly who blocked them, and tell a blocker that the person they
-- blocked is standing on that line right now.
--
-- Applied live to tbgcinfhgskcjoevfkea 2026-09-04 and proved: a blocked device
-- got 'blocked', a device already in the squad still got 'ok'.
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

    -- A block between the caller and anybody already on the line, in either
    -- direction, closes the door. Counted as a failed attempt so a blocked
    -- person hammering the code meets the same backoff as anyone else.
    if p_device_id is not null and not already
       and exists (
           select 1
           from public.squad_members m
           join public.blocks b
             on (b.blocker_device = p_device_id and b.blocked_device = m.device_id)
             or (b.blocker_device = m.device_id and b.blocked_device = p_device_id)
           where m.squad_id = existing.id
       ) then
        insert into public.join_attempts (code, device_id, succeeded, client_ip)
        values (p_code, p_device_id, false, ip);
        return query select 'blocked'::text, 0, null::uuid, null::text, null::text, false;
        return;
    end if;

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