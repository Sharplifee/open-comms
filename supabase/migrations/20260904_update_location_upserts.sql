-- update_location was an UPDATE with no INSERT, so a device with no row wrote
-- its position into nothing, every eight seconds, forever. It never errored —
-- zero rows updated is a perfectly successful UPDATE — so the phone believed
-- it was on the radar while being invisible to everybody.
--
-- A device ends up with no row easily: registerDevice was called once, at name
-- entry, so anybody who used the app before that call existed never had one,
-- and "Delete my data" deliberately removes it while the app keeps running.
--
-- Upsert instead. A position arriving for an unknown device is not an error,
-- it is a device saying where it is.
--
-- Applied live to tbgcinfhgskcjoevfkea 2026-09-04 and proved: an unknown
-- device id created a row with a position, and a device already flagged hidden
-- came out with latitude and location_updated_at still null.
CREATE OR REPLACE FUNCTION public.update_location(p_device_id text, p_lat double precision, p_lon double precision)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    insert into public.devices (device_id, latitude, longitude,
                                location_updated_at, last_seen_at)
    values (p_device_id, p_lat, p_lon, now(), now())
    on conflict (device_id) do update
        set latitude            = case when devices.is_ghost_mode then null else excluded.latitude end,
            longitude           = case when devices.is_ghost_mode then null else excluded.longitude end,
            -- Hidden stays hidden. The insert path cannot be ghosted yet, and
            -- on the update path the stored flag wins over the incoming write,
            -- so turning hidden on is never undone by a location tick that was
            -- already in flight.
            location_updated_at = case when devices.is_ghost_mode then null else now() end,
            last_seen_at        = now();
end;
$function$
;