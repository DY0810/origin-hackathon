-- "Post a bounty" from the buyer dashboard (CLAUDE.md §6.7, §11 step 3). The buyer Edge Function validates
-- the input and calls these with the service role; map-data turns the new row into heat on the app map.

-- Rejects self-intersecting or zero-area shapes (errcode 22023, the Edge Function answers 400).
create function public.post_bounty(p_name text, p_multiplier real, p_area text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  g extensions.geometry := extensions.st_geomfromtext(p_area, 4326);
  b public.bounties;
begin
  if not extensions.st_isvalid(g) then raise exception 'invalid polygon' using errcode = '22023'; end if;
  insert into public.bounties (name, multiplier, area, buyer)
  values (p_name, p_multiplier, g::extensions.geography, 'Dashboard')
  returning * into b;
  return json_build_object('id', b.id, 'name', b.name, 'multiplier', b.multiplier);
end $$;

-- Active bounties with their areas as GeoJSON, for the dashboard map.
create function public.active_bounties() returns json language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(json_build_object('id', id, 'name', name, 'multiplier', multiplier,
                                             'area', extensions.st_asgeojson(area)::json) order by created_at), '[]'::json)
  from public.bounties
  where starts_at <= now() and (ends_at is null or ends_at > now())
$$;

revoke execute on function public.post_bounty, public.active_bounties from public, anon, authenticated;
