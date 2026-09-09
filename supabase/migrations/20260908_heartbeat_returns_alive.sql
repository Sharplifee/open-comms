-- The heartbeat returned void, so a phone had no way to learn that its line
-- had ended. The end-of-line broadcast only reaches a phone that is connected;
-- one that was asleep, or briefly offline, sat on a dead line showing a code
-- nobody could join, indefinitely.
--
-- It now answers with whether the line is still alive, which costs nothing —
-- the row is already being touched — and gives the app a backstop that does
-- not depend on having been awake at the right moment.
--
-- Postgres will not change a function's return type in place, so this drops
-- and recreates, and the grant has to be reapplied with it.
--
-- Applied live to tbgcinfhgskcjoevfkea 2026-09-08 and proved: true while the
-- line was open, false immediately after end_squad.
drop function if exists public.heartbeat(uuid, text);

create function public.heartbeat(p_squad_id uuid, p_device_id text)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    alive boolean;
begin
    update public.squad_members set last_seen_at = now()
    where squad_id = p_squad_id and device_id = p_device_id;

    update public.devices set last_seen_at = now() where device_id = p_device_id;

    update public.squads set expires_at = greatest(expires_at, now() + interval '2 hours')
    where id = p_squad_id and ended_at is null;

    select exists (
        select 1 from public.squads s
        where s.id = p_squad_id and s.ended_at is null and s.expires_at > now()
    ) into alive;

    return alive;
end;
$function$;

grant execute on function public.heartbeat(uuid, text) to anon;
