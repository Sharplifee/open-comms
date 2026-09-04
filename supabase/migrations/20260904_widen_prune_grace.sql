-- A gym is exactly where a phone loses signal: a basement rack, a pocket, a
-- lift. The client heartbeats every 45s, and a two-minute idle window meant a
-- two-minute dead zone deleted you from a line you were standing in — and if
-- that emptied the squad, the line ended and the code was handed to anybody.
--
-- Nothing user-visible depended on the tight window: the member list on screen
-- comes from LiveKit room events, not from this table. These rows exist for
-- seat counting and squad lifetime, so a longer grace costs nothing and stops
-- a bad ten seconds of reception from closing a line people are still on.
--
-- Applied live to tbgcinfhgskcjoevfkea on 2026-09-04 and recorded here so the
-- values cannot quietly revert. Runs on the prune-stale-members cron, */2.
create or replace function public.prune_stale_members()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
    delete from public.squad_members where last_seen_at < now() - interval '6 minutes';

    -- Only close a squad nobody has been on for a while. The previous rule
    -- could end a five-minute-old line the instant its members were pruned.
    update public.squads s set ended_at = now(), expires_at = now()
    where s.ended_at is null
      and not exists (select 1 from public.squad_members m where m.squad_id = s.id)
      and s.created_at < now() - interval '10 minutes';
end;
$function$;
