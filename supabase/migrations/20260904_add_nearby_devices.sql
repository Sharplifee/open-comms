-- The app wrote its own position every eight seconds and never once asked who
-- else was there. There was no function to ask — the whole nearby feature, the
-- radar included, rendered an array nothing ever filled, so the empty state
-- was the only state anybody ever saw.
--
-- Distance and bearing are computed HERE and only those are returned. Handing
-- back other people's coordinates would make every user a tracker: you would
-- know not just that somebody is close, but exactly where they are standing.
-- Haversine rather than PostGIS, because one great-circle distance does not
-- justify an extension.
--
-- Applied live to tbgcinfhgskcjoevfkea 2026-09-04 and proved with seeded rows:
-- a device 34 m away came back at bearing 61°, one 4 km away did not, a
-- location older than fifteen minutes did not, a ghosted device did not, and
-- adding a block in either direction dropped the count to zero.
CREATE OR REPLACE FUNCTION public.nearby_devices(p_device_id text, p_lat double precision, p_lon double precision, p_radius_m double precision DEFAULT 152)
 RETURNS TABLE(device_id text, display_name text, metres double precision, bearing double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    with me as (select radians(p_lat) as lat, radians(p_lon) as lon)
    select d.device_id,
           d.display_name,
           6371000 * 2 * asin(sqrt(
               power(sin((radians(d.latitude) - me.lat) / 2), 2)
             + cos(me.lat) * cos(radians(d.latitude))
             * power(sin((radians(d.longitude) - me.lon) / 2), 2)
           )) as metres,
           atan2(
               sin(radians(d.longitude) - me.lon) * cos(radians(d.latitude)),
               cos(me.lat) * sin(radians(d.latitude))
             - sin(me.lat) * cos(radians(d.latitude)) * cos(radians(d.longitude) - me.lon)
           ) as bearing
    from public.devices d, me
    where d.device_id <> p_device_id
      -- Hidden means hidden. set_ghost_mode also nulls the coordinates, so
      -- this is belt and braces rather than the only guard.
      and d.is_ghost_mode = false
      and d.latitude is not null
      and d.longitude is not null
      -- A position nobody has refreshed in a quarter of an hour is not
      -- evidence that somebody is in the room. purge_stale_locations clears
      -- these anyway; this makes the read agree with the write.
      and d.location_updated_at > now() - interval '15 minutes'
      -- Blocks cut both ways here for the same reason they do at the door:
      -- neither person should be shown as available to the other.
      and not exists (
          select 1 from public.blocks b
          where (b.blocker_device = p_device_id and b.blocked_device = d.device_id)
             or (b.blocker_device = d.device_id and b.blocked_device = p_device_id)
      )
      and 6371000 * 2 * asin(sqrt(
              power(sin((radians(d.latitude) - me.lat) / 2), 2)
            + cos(me.lat) * cos(radians(d.latitude))
            * power(sin((radians(d.longitude) - me.lon) / 2), 2)
          )) <= p_radius_m
    order by metres asc
    limit 20;
$function$
;
grant execute on function public.nearby_devices(text, double precision, double precision, double precision) to anon;
