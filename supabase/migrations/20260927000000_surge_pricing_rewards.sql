-- Surge pricing, rate-card tiers + itemized receipt, bounty budgets, merchant partner offers
-- (CLAUDE.md §6.4, §6.6, docs/surge-and-rewards.md).
-- Builds on *_rewards.sql (catalog, redeem), *_danger_zones.sql (in_danger) and *_first_finder.sql (first finder /
-- confirmation at 40%): those rules are unchanged. This adds live per-cell pricing (supabase/functions/_shared/surge.ts,
-- shared by map-data and verify-report), asset tiers, a gallery discount, a daily cap, the `why` receipt, bounty budgets,
-- and merchant-funded partner offers in the catalog.

-- ── Bounty budgets ─────────────────────────────────────────────────────────────────────────────────────────
-- A bounty stops heating the map (and paying its multiplier) once the points paid inside it reach budget_points.
alter table public.bounties add column budget_points integer check (budget_points > 0);

alter table public.reports
  add column h3_cell text,
  add column multiplier real,
  add column bounty_id uuid references public.bounties (id) on delete set null;
create index reports_bounty_idx on public.reports (bounty_id) where bounty_id is not null;

create function public.bounty_spent(p_bounty uuid) returns integer language sql stable set search_path = '' as $$
  select coalesce(sum(points_pending), 0)::integer from public.reports where bounty_id = p_bounty
$$;

create function public.bounty_live(b public.bounties) returns boolean language sql stable set search_path = '' as $$
  select b.starts_at <= now() and (b.ends_at is null or b.ends_at > now())
     and (b.budget_points is null or public.bounty_spent(b.id) < b.budget_points)
$$;

-- Same as *_danger_zones.sql, but an exhausted bounty stops counting. award_report falls back to this when
-- verify-report couldn't quote a zone price (outbox retries).
create or replace function public.multiplier_at(p_geom extensions.geography) returns real language sql stable set search_path = '' as $$
  select case when public.in_danger(p_geom) then 1 else coalesce(max(b.multiplier), 1) end::real from public.bounties b
  where p_geom is not null and extensions.st_intersects(b.area, p_geom) and public.bounty_live(b)
$$;

-- ── Zone inputs (feeds surge.ts) ───────────────────────────────────────────────────────────────────────────
-- p_cells: [{h3, lat, lng}] with lat/lng = the H3 cell center. Membership uses the center (same rule as h3-js
-- polygonToCells, so the painted hex and the paid multiplier agree). Supply counts reports within 175 m of the
-- center (≈ one res-9 cell); a circle, not the exact hexagon, which is close enough for a price signal.
create function public.zone_inputs(p_cells jsonb) returns json
language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(json_build_object(
      'h3', c.h3,
      'bounty_id', b.id, 'bounty_name', b.name, 'bounty_multiplier', b.multiplier,
      'surge', exists (select 1 from public.bounties sb
                       where sb.surge and public.bounty_live(sb) and extensions.st_intersects(sb.area, p.g)),
      'danger', public.in_danger(p.g),
      'reports_24h', s.recent,
      'last_report_at', s.last_at)), '[]'::json)
  from jsonb_to_recordset(p_cells) as c(h3 text, lat double precision, lng double precision)
  cross join lateral (select extensions.st_setsrid(extensions.st_makepoint(c.lng, c.lat), 4326)::extensions.geography as g) p
  left join lateral (
    select bo.id, bo.name, bo.multiplier from public.bounties bo
    where extensions.st_intersects(bo.area, p.g) and public.bounty_live(bo)
    order by bo.multiplier desc limit 1
  ) b on true
  cross join lateral (
    select (count(*) filter (where r.created_at > now() - interval '24 hours'))::integer as recent, max(r.created_at) as last_at
    from public.reports r
    where r.status <> 'rejected' and r.geom is not null and extensions.st_dwithin(r.geom, p.g, 175)
  ) s
$$;

-- ── Rate card (§6.6) ───────────────────────────────────────────────────────────────────────────────────────
-- 100 points = $1 (points_per_dollar, *_rewards.sql). Base by severity is the game layer's 10/25/50/80/120, then
-- × asset tier. Deterministic and explained on every receipt (MASTER §9).
create function public.severity_points(p_severity integer) returns integer language sql immutable as $$
  select (array[10, 25, 50, 80, 120])[p_severity]
$$;

create function public.damage_tier(p_type text) returns real language sql immutable as $$
  select (case
    when p_type in ('exposed_rebar', 'structural_collapse', 'bulge', 'detachment') then 1.5              -- structure at risk
    when p_type in ('leaning_or_damaged_pole', 'broken_sign_or_light', 'leakage', 'fire_damage') then 1.25 -- utility / safety device
    else 1 end)::real
$$;

create function public.tier_label(p_type text) returns text language sql immutable as $$
  select case public.damage_tier(p_type) when 1.5 then 'Structure at risk' when 1.25 then 'Utility or safety device' end
$$;

-- Rounded to 5 so receipts stay readable.
create function public.base_points(p_severity integer, p_type text) returns integer language sql immutable as $$
  select (round(public.severity_points(p_severity) * public.damage_tier(p_type) / 5) * 5)::integer
$$;

-- ── award_report: + zone price, tiers, gallery ×0.5, daily cap, receipt ────────────────────────────────────
-- Same rules as *_first_finder.sql (danger zones and GPS-less library photos earn nothing; first finder full,
-- confirmation 40%; XP full), plus:
--   points = base(severity) × tier × [library ×0.5] × [confirmation ×0.4] × zone × [×0.5 after 15 reports today]
-- p_zone: the ZonePrice surge.ts quoted for the report's cell, priced by verify-report *before* the report was inserted
-- (so a report doesn't count as coverage against itself). Null (library, no location, outbox retry) falls back to
-- multiplier_at. `why` is the itemized receipt the app shows.
drop function public.award_report(uuid);

create function public.award_report(p_report uuid, p_zone jsonb default null) returns json
language plpgsql security definer set search_path = '' as $$
declare
  r public.reports;
  q public.quests;
  base integer;
  tier real;
  mult real := 1;
  daily real := 1;
  today integer;
  pts integer;
  xp integer;
  xp_before integer;
  settle timestamptz;
  completed json[] := '{}';
  first_finder boolean;
  why text[] := '{}';
  kind_label text;
begin
  select * into r from public.reports where id = p_report;
  if r.id is null or r.user_id is null then raise exception 'report % missing or has no player', p_report; end if;
  if r.status = 'rejected' or r.severity is null or public.in_danger(r.geom) or (r.source = 'library' and r.geom is null) then
    return json_build_object('base_points', 0, 'multiplier', 1, 'points', 0, 'xp', 0, 'quests_completed', '[]'::json,
      'danger', public.in_danger(r.geom), 'first_finder', null, 'why', '[]'::json,  -- nothing earned: neither tag
      'level_before', public.level_for_xp(public.xp_total(r.user_id)), 'level_after', public.level_for_xp(public.xp_total(r.user_id)));
  end if;

  -- First finder: unchanged from *_first_finder.sql (same OSM asset, else 15 m + same type, 30 days).
  first_finder := not exists (
    select 1 from public.reports o
    where o.id <> r.id and o.status <> 'rejected' and (o.points_pending > 0 or o.status = 'review')
      and o.created_at < r.created_at and o.created_at >= r.created_at - interval '30 days'
      and ((r.asset_osm_id is not null and o.asset_osm_id = r.asset_osm_id)
           or (r.geom is not null and extensions.st_dwithin(o.geom, r.geom, 15) and o.primary_type = r.primary_type
               and (r.asset_osm_id is null or o.asset_osm_id is null))));

  kind_label := replace(coalesce(r.primary_type, 'damage'), '_', ' ');
  tier := public.damage_tier(r.primary_type);
  base := public.base_points(r.severity, r.primary_type);
  why := why || format('Severity %s %s: %s pts', r.severity, kind_label, public.severity_points(r.severity));
  if tier > 1 then why := why || format('%s: ×%s', public.tier_label(r.primary_type), tier); end if;
  if r.source <> 'camera' then
    base := ceil(base / 2.0)::integer;  -- older, unverifiable timing (§6.3)
    why := why || 'From your photo library: ×0.5'::text;
  end if;
  -- Confirmations still pay (they track progression, §6.5) but 40%, so re-shooting a known defect isn't a farm.
  if first_finder then
    why := why || 'First finder: full points'::text;
  else
    base := round(base * 0.4);
    why := why || 'Confirms a report from the last 30 days: ×0.4'::text;
  end if;

  if r.source = 'camera' then  -- library photos have no trustworthy location
    mult := greatest(1, least(5, coalesce(nullif(p_zone->>'multiplier', '')::real, public.multiplier_at(r.geom))));
    if mult > 1 then
      why := why || array(select jsonb_array_elements_text(coalesce(p_zone->'why', '[]'::jsonb))) || format('Zone: ×%s', mult);
    end if;
  end if;

  select count(*) into today from public.reports
  where user_id = r.user_id and id <> r.id and status <> 'rejected' and created_at >= date_trunc('day', now());
  if today >= 15 then
    daily := 0.5;  -- diminishing returns per player per day (§8)
    why := why || '15+ reports today: ×0.5'::text;
  end if;

  pts := round(base * mult * daily);
  xp := 10 + 5 * r.severity;  -- XP stays full: XP isn't cash, and confirmations are engagement we want
  settle := case when r.status = 'accepted' then now() + interval '24 hours' end; -- review: held until a human decides
  xp_before := public.xp_total(r.user_id);

  insert into public.point_ledger (user_id, report_id, currency, amount, kind, settles_at, note) values
    (r.user_id, r.id, 'points', pts, 'earn', settle, coalesce(r.primary_type, 'damage') || case when first_finder then '' else ' · confirmation' end
                                                      || case when mult > 1 then ' · ' || mult || '× zone' else '' end),
    (r.user_id, r.id, 'xp', xp, 'earn', null, null);
  update public.reports set
    points_pending = pts, is_first_finder = first_finder, multiplier = mult, h3_cell = p_zone->>'h3',
    bounty_id = case when r.source = 'camera' and mult > 1 then coalesce(nullif(p_zone->>'bounty_id', '')::uuid, (
      select b.id from public.bounties b
      where r.geom is not null and extensions.st_intersects(b.area, r.geom) and public.bounty_live(b)
      order by b.multiplier desc limit 1)) end
  where id = r.id;

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
    'base_points', base, 'multiplier', mult, 'points', pts, 'xp', xp, 'danger', false, 'first_finder', first_finder,
    'why', to_json(why), 'zone_name', case when mult > 1 then p_zone->>'name' end,
    'quests_completed', array_to_json(completed),
    'level_before', public.level_for_xp(xp_before), 'level_after', public.level_for_xp(public.xp_total(r.user_id)));
end $$;

-- ── Merchant partner offers in the catalog (the CRED model) ────────────────────────────────────────────────
-- A partner offer is funded by the merchant to win the visit, so it costs Mend nothing (dollars = 0) and is
-- priced in points directly, below gift-card value. Gift cards keep *_rewards.sql pricing (dollars × points_per_dollar).
alter table public.reward_catalog
  add column kind text not null default 'gift_card' check (kind in ('gift_card', 'partner_offer', 'donation')),
  add column points integer check (points > 0),  -- set for partner offers; null = dollars × points_per_dollar
  add column partner text,
  add column detail text;
alter table public.reward_catalog drop constraint reward_catalog_dollars_check;
alter table public.reward_catalog
  add constraint reward_catalog_dollars_check check (dollars >= 0),  -- dollars = what one redemption costs Mend
  add constraint reward_catalog_price_check check (points is not null or dollars > 0);

-- Brand-neutral placeholders (MASTER §7.5) until real merchants sign. Negative sort: partner offers list first.
insert into public.reward_catalog (sku, name, dollars, sort, kind, points, partner, detail) values
  ('partner-bike', '20% off a bike tune-up', 0, -3, 'partner_offer', 100, 'Partner bike shop', 'At a neighborhood partner bike shop.'),
  ('partner-coffee', 'Free coffee', 0, -2, 'partner_offer', 150, 'Partner café', 'Any size drip coffee at a partner café.'),
  ('partner-lunch', '2-for-1 lunch', 0, -1, 'partner_offer', 300, 'Partner restaurant', 'Weekday lunch at a partner restaurant.'),
  ('donate-fixit', '$5 to the neighborhood fix-it fund', 5, 10, 'donation', null, null, 'Pooled toward small repairs the city hasn''t scheduled.');

-- Same as *_rewards.sql, but priced by catalog_points(), and the $5 minimum (a gift-card API floor) only applies to
-- rewards that cost Mend cash; a 150-point partner coffee is redeemable on its own.
create function public.catalog_points(c public.reward_catalog) returns integer language sql stable set search_path = '' as $$
  select coalesce(c.points, c.dollars * public.points_per_dollar())
$$;

create or replace function public.redeem(p_sku text) returns json language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  item public.reward_catalog;
  price integer;
  balance integer;
  mock_code text := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
begin
  if me is null then raise exception 'sign in required' using errcode = '28000'; end if;
  select * into item from public.reward_catalog where sku = p_sku;
  if item.sku is null then raise exception 'That reward isn''t available.' using errcode = 'P0002'; end if;
  price := public.catalog_points(item);
  perform public.ensure_profile(me);
  perform 1 from public.profiles where id = me for update;

  select coalesce(sum(amount), 0) into balance from public.point_ledger
  where user_id = me and currency = 'points' and settles_at <= now();
  if balance < greatest(price, case when item.kind = 'partner_offer' then 0 else public.min_redeem_points() end) then
    raise exception 'Not enough available points. Pending points count once they settle.' using errcode = 'FL001';
  end if;

  mock_code := 'FL-' || substr(mock_code, 1, 4) || '-' || substr(mock_code, 5, 4);
  insert into public.point_ledger (user_id, currency, amount, kind, settles_at, note)
  values (me, 'points', -price, 'redeem', now(), 'Redeemed: ' || item.name);
  insert into public.redemptions (user_id, sku, points, code) values (me, item.sku, price, mock_code);
  return json_build_object('code', mock_code, 'sku', item.sku, 'points', price, 'balance', balance - price);
end $$;

-- game_state: same as *_danger_zones.sql, but catalog items carry kind / partner / detail and their real price, plus
-- the rate card for the Rewards tab's "How points work".
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
      select json_agg(json_build_object('sku', c.sku, 'name', c.name, 'points', public.catalog_points(c), 'kind', c.kind,
                                        'partner', c.partner, 'detail', c.detail) order by c.sort, c.sku)
      from public.reward_catalog c
    ), '[]'::json),
    'redemptions', coalesce((
      select json_agg(json_build_object('id', r.id, 'name', c.name, 'points', r.points, 'code', r.code,
                                        'status', r.status, 'created_at', r.created_at) order by r.created_at desc)
      from public.redemptions r join public.reward_catalog c on c.sku = r.sku
      where r.user_id = me
    ), '[]'::json),
    'severity_points', json_build_array(public.severity_points(1), public.severity_points(2), public.severity_points(3),
                                        public.severity_points(4), public.severity_points(5)),
    'points_per_dollar', public.points_per_dollar()
  );
end $$;

-- ── Dashboard: post_bounty + budget, active_bounties + spend, map_data − exhausted bounties ────────────────
drop function public.post_bounty(text, real, text, boolean);

-- Same as *_surge.sql plus p_budget. Rejects self-intersecting or zero-area shapes (22023).
create function public.post_bounty(p_name text, p_multiplier real, p_area text, p_surge boolean default false,
                                   p_budget integer default null) returns json
language plpgsql security definer set search_path = '' as $$
declare
  g extensions.geometry := extensions.st_geomfromtext(p_area, 4326);
  b public.bounties;
begin
  if not extensions.st_isvalid(g) then raise exception 'invalid polygon' using errcode = '22023'; end if;
  insert into public.bounties (name, multiplier, area, buyer, surge, budget_points)
  values (p_name, p_multiplier, g::extensions.geography, 'Dashboard', p_surge, p_budget)
  returning * into b;
  if p_surge then  -- same shape as the seeded Arts District storm quest
    insert into public.quests (title, description, target_count, bounty_id, reward_points, reward_xp, ends_at)
    values ('Storm sweep: ' || b.name, 'Document 2 storm-damaged structures in ' || b.name || '.', 2, b.id, 200, 80,
            now() + interval '3 days');
  end if;
  return json_build_object('id', b.id, 'name', b.name, 'multiplier', b.multiplier, 'surge', b.surge, 'budget_points', b.budget_points);
end $$;

create or replace function public.active_bounties() returns json language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(json_build_object('id', b.id, 'name', b.name, 'multiplier', b.multiplier, 'surge', b.surge,
                                             'budget_points', b.budget_points, 'spent_points', public.bounty_spent(b.id),
                                             'area', extensions.st_asgeojson(b.area)::json) order by b.created_at), '[]'::json)
  from public.bounties b
  where public.bounty_live(b)
$$;

-- map_data: same as *_danger_zones.sql, but a bounty whose budget is spent drops off like an ended one.
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
        where public.bounty_live(bo) and extensions.st_intersects(bo.area, box.g)
      ) b
    ), '[]'::json),
    'danger_zones', coalesce((
      select json_agg(json_build_object('id', d.id, 'name', d.name, 'area', extensions.st_asgeojson(d.area)::json))
      from public.danger_zones d
      where d.starts_at <= now() and (d.ends_at is null or d.ends_at > now())
    ), '[]'::json)
  )
$$;

-- drop + create reset privileges: service role only, like the originals.
revoke execute on function public.zone_inputs, public.award_report, public.bounty_spent, public.bounty_live,
  public.post_bounty, public.active_bounties, public.catalog_points from public, anon, authenticated;
