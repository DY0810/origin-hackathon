-- Danger zones (CLAUDE.md §6.8 safety gates, §8 "Trespassing / danger"; MASTER.md principle 7): evacuation / fire / flood
-- perimeters drawn from the buyer dashboard. Inside an active one nothing pays: no points, no XP, no zone multiplier, and
-- quests whose bounty touches it are hidden (and don't pay). The report itself is still stored: the data matters, the incentive doesn't.
-- Own table rather than a flag on bounties: every bounty reader (multiplier_at, heat cells, quests, surge queue, labels)
-- would otherwise need a "but not danger" filter, and a danger zone has no multiplier or buyer.
-- ponytail: drawn by hand; NWS / CAL FIRE / USGS perimeter feeds fill this table when there's an ops owner.

create table public.danger_zones (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  area extensions.geography(polygon, 4326) not null,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  created_at timestamptz not null default now()
);
create index danger_zones_area_idx on public.danger_zones using gist (area);
alter table public.danger_zones enable row level security;

-- True if the point / area touches any active danger zone. Null -> false.
create function public.in_danger(p_geom extensions.geography) returns boolean language sql stable set search_path = '' as $$
  select exists (select 1 from public.danger_zones d
                 where p_geom is not null and extensions.st_intersects(d.area, p_geom)
                   and d.starts_at <= now() and (d.ends_at is null or d.ends_at > now()))
$$;

-- Same as 20260925020000_game.sql, but 1 inside a danger zone (the camera chip never advertises a bonus there).
create or replace function public.multiplier_at(p_geom extensions.geography) returns real language sql stable set search_path = '' as $$
  select case when public.in_danger(p_geom) then 1 else coalesce(max(b.multiplier), 1) end::real from public.bounties b
  where p_geom is not null and extensions.st_intersects(b.area, p_geom)
    and b.starts_at <= now() and (b.ends_at is null or b.ends_at > now())
$$;

-- Same shape as post_bounty: rejects self-intersecting or zero-area shapes (22023).
create function public.post_danger_zone(p_name text, p_area text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  g extensions.geometry := extensions.st_geomfromtext(p_area, 4326);
  d public.danger_zones;
begin
  if not extensions.st_isvalid(g) then raise exception 'invalid polygon' using errcode = '22023'; end if;
  insert into public.danger_zones (name, area) values (p_name, g::extensions.geography) returning * into d;
  return json_build_object('id', d.id, 'name', d.name);
end $$;

-- Declares an active danger zone safe now. P0002 when it doesn't exist or already ended.
create function public.end_danger_zone(p_id uuid) returns json
language plpgsql security definer set search_path = '' as $$
begin
  update public.danger_zones set ends_at = now()
  where id = p_id and starts_at <= now() and (ends_at is null or ends_at > now());
  if not found then raise exception 'danger zone not found' using errcode = 'P0002'; end if;
  return json_build_object('id', p_id, 'ended', true);
end $$;

-- Active danger zones with their areas as GeoJSON, for the dashboard map.
create function public.active_danger_zones() returns json language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(json_build_object('id', id, 'name', name, 'area', extensions.st_asgeojson(area)::json)
                           order by created_at), '[]'::json)
  from public.danger_zones
  where starts_at <= now() and (ends_at is null or ends_at > now())
$$;

-- award_report: same as 20260925020000_game.sql, plus: a report inside a danger zone earns nothing (danger: true in the
-- result so the app can say why), and quests whose bounty touches a danger zone don't pay out.
-- Applies to every source, not just camera: a gallery photo from inside the perimeter is still an incentive to go in.
-- Also: a library photo with no GPS earns nothing (CLAUDE.md §6.3: only GPS-tagged gallery photos qualify).
-- ponytail: a danger-zone report still counts toward quest_progress once the zone ends; exclude it there if that matters.
create or replace function public.award_report(p_report uuid) returns json language plpgsql security definer set search_path = '' as $$
declare
  r public.reports;
  q public.quests;
  base integer;
  mult real := 1;
  pts integer;
  xp integer;
  xp_before integer;
  settle timestamptz;
  completed json[] := '{}';
begin
  select * into r from public.reports where id = p_report;
  if r.id is null or r.user_id is null then raise exception 'report % missing or has no player', p_report; end if;
  if r.status = 'rejected' or r.severity is null or public.in_danger(r.geom) or (r.source = 'library' and r.geom is null) then
    return json_build_object('base_points', 0, 'multiplier', 1, 'points', 0, 'xp', 0, 'quests_completed', '[]'::json,
      'danger', public.in_danger(r.geom),
      'level_before', public.level_for_xp(public.xp_total(r.user_id)), 'level_after', public.level_for_xp(public.xp_total(r.user_id)));
  end if;

  base := (array[10, 25, 50, 80, 120])[r.severity];
  if r.source = 'camera' then mult := public.multiplier_at(r.geom); end if; -- library photos have no trustworthy location
  pts := round(base * mult);
  xp := 10 + 5 * r.severity;
  settle := case when r.status = 'accepted' then now() + interval '24 hours' end; -- review: held until a human decides
  xp_before := public.xp_total(r.user_id);

  insert into public.point_ledger (user_id, report_id, currency, amount, kind, settles_at, note) values
    (r.user_id, r.id, 'points', pts, 'earn', settle, coalesce(r.primary_type, 'damage') || case when mult > 1 then ' · ' || mult || '× zone' else '' end),
    (r.user_id, r.id, 'xp', xp, 'earn', null, null);
  update public.reports set points_pending = pts where id = r.id;

  for q in select * from public.quests
           where starts_at <= now() and (ends_at is null or ends_at > now())
             and not exists (select 1 from public.point_ledger l where l.user_id = r.user_id and l.quest_id = quests.id)
             and not exists (select 1 from public.bounties b where b.id = quests.bounty_id and public.in_danger(b.area))
  loop
    if public.quest_progress(r.user_id, q) >= q.target_count then
      insert into public.point_ledger (user_id, quest_id, currency, amount, kind, settles_at, note) values
        (r.user_id, q.id, 'points', q.reward_points, 'quest', now() + interval '24 hours', q.title),
        (r.user_id, q.id, 'xp', q.reward_xp, 'quest', null, q.title);
      completed := completed || json_build_object('title', q.title, 'reward_points', q.reward_points, 'reward_xp', q.reward_xp);
    end if;
  end loop;

  return json_build_object(
    'base_points', base, 'multiplier', mult, 'points', pts, 'xp', xp, 'danger', false,
    'quests_completed', array_to_json(completed),
    'level_before', public.level_for_xp(xp_before), 'level_after', public.level_for_xp(public.xp_total(r.user_id)));
end $$;

-- game_state: same as 20260926030000_rewards.sql, but quests whose bounty touches a danger zone are hidden (MASTER.md §9).
create or replace function public.game_state() returns json language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  xp integer;
  lvl integer;
  week_start timestamptz := date_trunc('week', now());
begin
  if me is null then raise exception 'sign in required' using errcode = '28000'; end if;
  perform public.ensure_profile(me);
  xp := public.xp_total(me);
  lvl := public.level_for_xp(xp);
  return json_build_object(
    'handle', (select handle from public.profiles where id = me),
    'xp', xp,
    'level', lvl,
    'title', public.title_for_level(lvl),
    'level_start_xp', 25 * (lvl - 1) * (lvl - 1),
    'next_level_xp', 25 * lvl * lvl,
    'points_settled', (select coalesce(sum(amount), 0) from public.point_ledger
                       where user_id = me and currency = 'points' and settles_at <= now()),
    'points_pending', (select coalesce(sum(amount), 0) from public.point_ledger
                       where user_id = me and currency = 'points' and (settles_at is null or settles_at > now())),
    'quests', coalesce((
      select json_agg(json_build_object(
        'id', q.id, 'title', q.title, 'description', q.description, 'target', q.target_count,
        'progress', least(public.quest_progress(me, q), q.target_count),
        'completed', exists (select 1 from public.point_ledger l where l.user_id = me and l.quest_id = q.id),
        'reward_points', q.reward_points, 'reward_xp', q.reward_xp, 'ends_at', q.ends_at,
        'multiplier', b.multiplier, 'area_name', b.name, 'surge', coalesce(b.surge, false)) order by q.ends_at nulls last, q.title)
      from public.quests q left join public.bounties b on b.id = q.bounty_id
      where q.starts_at <= now() and (q.ends_at is null or q.ends_at > now())
        and not public.in_danger(b.area)
    ), '[]'::json),
    'leaderboard', coalesce((
      with weekly as (
        select p.id, p.handle, coalesce(sum(l.amount) filter (where l.currency = 'points' and l.amount > 0 and l.created_at >= week_start), 0) as points
        from public.profiles p left join public.point_ledger l on l.user_id = p.id
        group by p.id, p.handle
      ), ranked as (
        select id, handle, points, rank() over (order by points desc) as rank from weekly where points > 0 or id = me
      )
      select json_agg(json_build_object('rank', rank, 'handle', handle, 'points', points, 'is_me', id = me) order by rank, handle)
      from ranked where rank <= 10 or id = me
    ), '[]'::json),
    'history', coalesce((
      select json_agg(h order by h.created_at desc) from (
        select l.amount, l.kind, l.note, l.created_at, (l.settles_at is not null and l.settles_at <= now()) as settled
        from public.point_ledger l where l.user_id = me and l.currency = 'points'
        order by l.created_at desc limit 20
      ) h
    ), '[]'::json),
    'min_redeem', public.min_redeem_points(),
    'catalog', coalesce((
      select json_agg(json_build_object('sku', sku, 'name', name, 'points', dollars * public.points_per_dollar()) order by sort, sku)
      from public.reward_catalog
    ), '[]'::json),
    'redemptions', coalesce((
      select json_agg(json_build_object('id', r.id, 'name', c.name, 'points', r.points, 'code', r.code,
                                        'status', r.status, 'created_at', r.created_at) order by r.created_at desc)
      from public.redemptions r join public.reward_catalog c on c.sku = r.sku
      where r.user_id = me
    ), '[]'::json)
  );
end $$;

-- map_data: same as 20260926020000_surge.sql plus every active danger zone (not just the box: panning away must not
-- hide the SafetyBanner or re-enable the Capture button while the player stands inside one).
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
    ), '[]'::json),
    'danger_zones', coalesce((
      select json_agg(json_build_object('id', d.id, 'name', d.name, 'area', extensions.st_asgeojson(d.area)::json))
      from public.danger_zones d
      where d.starts_at <= now() and (d.ends_at is null or d.ends_at > now())
    ), '[]'::json)
  )
$$;

revoke execute on function public.in_danger, public.post_danger_zone, public.end_danger_zone, public.active_danger_zones
  from public, anon, authenticated;
