-- Surge mode (CLAUDE.md §6.8, §11 step 5): a buyer flags a bounty as a disaster surge from the dashboard.
-- Surge bounties draw red and dashed, come with a storm-sweep quest, and double the priority of reports
-- inside them in the buyer queue. Ending a bounty closes it (and its quests) instead of deleting history.
-- ponytail: no danger/evacuation polygons yet (§6.8 safety gates); surge areas still pay rewards everywhere.

alter table public.bounties add column surge boolean not null default false;

-- post_bounty gains p_surge; drop the 3-arg version so PostgREST has one function to resolve.
drop function public.post_bounty(text, real, text);

-- Rejects self-intersecting or zero-area shapes (errcode 22023, the Edge Function answers 400).
create function public.post_bounty(p_name text, p_multiplier real, p_area text, p_surge boolean default false) returns json
language plpgsql security definer set search_path = '' as $$
declare
  g extensions.geometry := extensions.st_geomfromtext(p_area, 4326);
  b public.bounties;
begin
  if not extensions.st_isvalid(g) then raise exception 'invalid polygon' using errcode = '22023'; end if;
  insert into public.bounties (name, multiplier, area, buyer, surge)
  values (p_name, p_multiplier, g::extensions.geography, 'Dashboard', p_surge)
  returning * into b;
  if p_surge then  -- same shape as the seeded Arts District storm quest
    insert into public.quests (title, description, target_count, bounty_id, reward_points, reward_xp, ends_at)
    values ('Storm sweep: ' || b.name, 'Document 2 storm-damaged structures in ' || b.name || '.', 2, b.id, 200, 80,
            now() + interval '3 days');
  end if;
  return json_build_object('id', b.id, 'name', b.name, 'multiplier', b.multiplier, 'surge', b.surge);
end $$;

-- Ends an active bounty and its quests now. P0002 when it doesn't exist or already ended.
create function public.end_bounty(p_id uuid) returns json
language plpgsql security definer set search_path = '' as $$
begin
  update public.bounties set ends_at = now()
  where id = p_id and starts_at <= now() and (ends_at is null or ends_at > now());
  if not found then raise exception 'bounty not found' using errcode = 'P0002'; end if;
  update public.quests set ends_at = now() where bounty_id = p_id and (ends_at is null or ends_at > now());
  return json_build_object('id', p_id, 'ended', true);
end $$;

-- Same as 20260926010000_post_bounty.sql plus surge.
create or replace function public.active_bounties() returns json language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(json_build_object('id', id, 'name', name, 'multiplier', multiplier, 'surge', surge,
                                             'area', extensions.st_asgeojson(area)::json) order by created_at), '[]'::json)
  from public.bounties
  where starts_at <= now() and (ends_at is null or ends_at > now())
$$;

-- Ids of reports inside any active surge bounty (buyer queue: in_surge + doubled priority).
-- ponytail: scans all reports; join from surge bounties via the reports geom index and limit to the queue when reports grow
create function public.surge_report_ids() returns json language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(r.id), '[]'::json)
  from public.reports r
  where r.status <> 'rejected' and r.geom is not null and exists (
    select 1 from public.bounties b
    where b.surge and b.starts_at <= now() and (b.ends_at is null or b.ends_at > now())
      and extensions.st_intersects(b.area, r.geom))
$$;

revoke execute on function public.post_bounty, public.end_bounty, public.active_bounties, public.surge_report_ids
  from public, anon, authenticated;

-- map_data: same as 20260926000000_fixes.sql plus surge on each bounty.
create or replace function public.map_data(min_lng double precision, min_lat double precision, max_lng double precision, max_lat double precision)
returns json
language sql
stable
security definer
set search_path = ''
as $$
  with box as (
    select extensions.st_makeenvelope(min_lng, min_lat, max_lng, max_lat, 4326)::extensions.geography as g
  )
  select json_build_object(
    'reports', coalesce((
      select json_agg(r order by r.created_at desc)
      from (
        select rep.id, rep.latitude as lat, rep.longitude as lng, rep.severity, rep.primary_type, rep.status, rep.created_at,
               rep.fixed_at
        from public.reports rep, box
        where rep.status <> 'rejected' and rep.geom is not null and extensions.st_intersects(rep.geom, box.g)
        order by rep.created_at desc
        limit 500
      ) r
    ), '[]'::json),
    'bounties', coalesce((
      select json_agg(b)
      from (
        select bo.id, bo.name, bo.multiplier, bo.surge,
               extensions.st_asgeojson(bo.area)::json as area,
               extensions.st_ymax(bo.area::extensions.geometry) as label_lat,  -- north edge: keeps the label off the pins inside
               extensions.st_x(extensions.st_centroid(bo.area::extensions.geometry)) as label_lng
        from public.bounties bo, box
        where (bo.ends_at is null or bo.ends_at > now()) and bo.starts_at <= now()
          and extensions.st_intersects(bo.area, box.g)
      ) b
    ), '[]'::json)
  )
$$;
