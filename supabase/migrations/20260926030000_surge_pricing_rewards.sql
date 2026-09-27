-- Surge pricing, reward rate card and redemption (CLAUDE.md §6.4–6.6, §6.8, docs/surge-and-rewards.md).
-- Builds on *_post_bounty.sql and *_surge.sql: a surge is still a bounty flagged `surge`; this adds budgets,
-- danger cores and live per-cell pricing on top.
--
-- The multiplier itself is computed in supabase/functions/_shared/surge.ts (tested, shared by map-data and
-- verify-report). SQL supplies the raw inputs per H3 cell (zone_inputs) and applies the rate card (award_report).

-- ── Bounty budgets + danger cores ──────────────────────────────────────────────────────────────────────────
-- budget_points: the bounty stops heating the map once the points paid inside it reach this (null = open-ended).
-- danger_area: evacuation / fire / flood perimeter inside a surge. Pays nothing, so nobody is paid to go in (§6.8).
alter table public.bounties
  add column budget_points integer check (budget_points > 0),
  add column danger_area extensions.geography(polygon, 4326);
create index bounties_danger_idx on public.bounties using gist (danger_area);

alter table public.reports
  add column h3_cell text,
  add column multiplier real,
  add column finder text check (finder in ('first', 'confirmation', 'repeat')),
  add column bounty_id uuid references public.bounties (id) on delete set null;
create index reports_bounty_idx on public.reports (bounty_id) where bounty_id is not null;

create function public.bounty_spent(p_bounty uuid) returns integer language sql stable set search_path = '' as $$
  select coalesce(sum(points_pending), 0)::integer from public.reports where bounty_id = p_bounty
$$;

create function public.bounty_live(b public.bounties) returns boolean language sql stable set search_path = '' as $$
  select b.starts_at <= now() and (b.ends_at is null or b.ends_at > now())
     and (b.budget_points is null or public.bounty_spent(b.id) < b.budget_points)
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
      'danger', exists (select 1 from public.bounties d
                        where d.danger_area is not null and public.bounty_live(d) and extensions.st_intersects(d.danger_area, p.g)),
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
-- 100 points = $1. Base by severity, then × asset tier. Deterministic and explained on every receipt (MASTER §9).
create function public.damage_tier(p_type text) returns real language sql immutable as $$
  select (case
    when p_type in ('exposed_rebar', 'structural_collapse', 'bulge', 'detachment') then 1.5              -- structure at risk
    when p_type in ('leaning_or_damaged_pole', 'broken_sign_or_light', 'leakage', 'fire_damage') then 1.25 -- utility / safety device
    else 1 end)::real
$$;

create function public.tier_label(p_type text) returns text language sql immutable as $$
  select case public.damage_tier(p_type) when 1.5 then 'Structure at risk' when 1.25 then 'Utility or safety device' end
$$;

create function public.severity_points(p_severity integer) returns integer language sql immutable as $$
  select (array[10, 20, 30, 50, 80])[p_severity]
$$;

-- Rounded to 5 so receipts stay readable.
create function public.base_points(p_severity integer, p_type text) returns integer language sql immutable as $$
  select (round(public.severity_points(p_severity) * public.damage_tier(p_type) / 5) * 5)::integer
$$;

-- Repeats of your own find don't advance quests.
create or replace function public.quest_progress(p_user uuid, p_quest public.quests) returns integer language sql stable set search_path = '' as $$
  select count(*)::integer from public.reports r
  left join public.bounties b on b.id = p_quest.bounty_id
  where r.user_id = p_user and r.status in ('accepted', 'review') and r.finder is distinct from 'repeat'
    and r.created_at >= p_quest.starts_at and (p_quest.ends_at is null or r.created_at < p_quest.ends_at)
    and (p_quest.bounty_id is null or (r.geom is not null and extensions.st_intersects(b.area, r.geom)))
    and (p_quest.damage_types is null or r.damage_types && p_quest.damage_types)
$$;

-- ── award_report v2 ────────────────────────────────────────────────────────────────────────────────────────
-- p_zone: the ZonePrice from surge.ts for the report's cell, priced by verify-report *before* the report was
-- inserted (so a report doesn't count as coverage against itself). Null for library photos / no location.
--   points = base(severity) × tier × [library ×0.5] × zone × finder (first 1, confirmation ⅓, own repeat 0)
--            × daily (×0.5 after 15 reports today)
drop function public.award_report(uuid);

create function public.award_report(p_report uuid, p_zone jsonb default null) returns json
language plpgsql security definer set search_path = '' as $$
declare
  r public.reports;
  q public.quests;
  base integer;
  tier real;
  mult real := 1;
  danger boolean := coalesce((p_zone->>'danger')::boolean, false);
  finder_kind text;
  finder_factor real;
  today integer;
  daily_factor real := 1;
  pts integer;
  xp integer;
  xp_before integer;
  settle timestamptz;
  why text[] := '{}';
  completed json[] := '{}';
  kind_label text;
begin
  select * into r from public.reports where id = p_report;
  if r.id is null or r.user_id is null then raise exception 'report % missing or has no player', p_report; end if;
  xp_before := public.xp_total(r.user_id);
  if r.status = 'rejected' or r.severity is null then
    return json_build_object('base_points', 0, 'multiplier', 1, 'points', 0, 'xp', 0, 'finder', null, 'why', '[]'::json,
      'quests_completed', '[]'::json,
      'level_before', public.level_for_xp(xp_before), 'level_after', public.level_for_xp(xp_before));
  end if;

  kind_label := replace(coalesce(r.primary_type, 'damage'), '_', ' ');
  tier := public.damage_tier(r.primary_type);
  base := public.base_points(r.severity, r.primary_type);
  why := why || format('Severity %s %s: %s pts', r.severity, kind_label, public.severity_points(r.severity));
  if tier > 1 then why := why || format('%s: ×%s', public.tier_label(r.primary_type), tier); end if;

  if r.source <> 'camera' then
    base := ceil(base / 2.0)::integer;  -- no trustworthy time or place, so half and no zone (§6.3)
    why := why || 'From your photo library: ×0.5'::text;
  elsif danger then
    mult := 0;
    why := why || 'Danger area: no points here. Please stay safe.'::text;
  elsif p_zone is not null then
    mult := greatest(1, least(5, (p_zone->>'multiplier')::real));
    if mult <> 1 then
      why := why || array(select jsonb_array_elements_text(coalesce(p_zone->'why', '[]'::jsonb)))
                 || format('Zone: ×%s', mult);
    end if;
  end if;

  -- First finder vs confirmation (§6.5): same type within 25 m in 14 days, not yet fixed.
  select case when count(*) = 0 then 'first' when bool_or(o.user_id = r.user_id) then 'repeat' else 'confirmation' end
  into finder_kind
  from public.reports o
  where o.id <> r.id and o.status <> 'rejected' and o.fixed_at is null
    and o.primary_type is not distinct from r.primary_type
    and o.created_at > now() - interval '14 days'
    and r.geom is not null and o.geom is not null and extensions.st_dwithin(o.geom, r.geom, 25);
  finder_factor := case finder_kind when 'first' then 1 when 'confirmation' then 1 / 3.0 else 0 end;
  why := why || case finder_kind
    when 'first' then 'First finder: full points'
    when 'confirmation' then 'Confirms an open report: ×⅓'
    else 'You already reported this one: no points' end;

  select count(*) into today from public.reports
  where user_id = r.user_id and id <> r.id and status <> 'rejected' and created_at >= date_trunc('day', now());
  if today >= 15 then
    daily_factor := 0.5;
    why := why || '15+ reports today: ×0.5'::text;
  end if;

  pts := round(base * mult * finder_factor * daily_factor);
  xp := case when finder_kind = 'repeat' or danger then 0 else 10 + 5 * r.severity end;
  settle := case when r.status = 'accepted' then now() + interval '24 hours' end; -- review: held until a human decides

  if pts > 0 then
    insert into public.point_ledger (user_id, report_id, currency, amount, kind, settles_at, note) values
      (r.user_id, r.id, 'points', pts, 'earn', settle,
       kind_label || case when mult > 1 then ' · ' || mult || '× zone' else '' end
                  || case when finder_kind = 'confirmation' then ' · confirmation' else '' end);
  end if;
  if xp > 0 then
    insert into public.point_ledger (user_id, report_id, currency, amount, kind, settles_at, note)
    values (r.user_id, r.id, 'xp', xp, 'earn', null, null);
  end if;
  update public.reports set
    points_pending = pts, multiplier = mult, finder = finder_kind, h3_cell = p_zone->>'h3',
    bounty_id = case when mult > 0 and r.source = 'camera' then nullif(p_zone->>'bounty_id', '')::uuid end
  where id = r.id;

  if finder_kind <> 'repeat' and not danger then
    for q in select * from public.quests
             where starts_at <= now() and (ends_at is null or ends_at > now())
               and not exists (select 1 from public.point_ledger l where l.user_id = r.user_id and l.quest_id = quests.id)
    loop
      if public.quest_progress(r.user_id, q) >= q.target_count then
        insert into public.point_ledger (user_id, quest_id, currency, amount, kind, settles_at, note) values
          (r.user_id, q.id, 'points', q.reward_points, 'quest', now() + interval '24 hours', q.title),
          (r.user_id, q.id, 'xp', q.reward_xp, 'quest', null, q.title);
        completed := completed || json_build_object('title', q.title, 'reward_points', q.reward_points, 'reward_xp', q.reward_xp);
      end if;
    end loop;
  end if;

  return json_build_object(
    'base_points', base, 'multiplier', mult, 'points', pts, 'xp', xp, 'finder', finder_kind,
    'zone_name', case when mult > 1 then p_zone->>'name' end,
    'why', to_json(why),
    'quests_completed', array_to_json(completed),
    'level_before', public.level_for_xp(xp_before), 'level_after', public.level_for_xp(public.xp_total(r.user_id)));
end $$;

-- ── post_bounty v3: + budget, + danger core ────────────────────────────────────────────────────────────────
-- p_danger (surge only): the middle of the drawn area, scaled to 40% around its centroid, pays nothing.
drop function public.post_bounty(text, real, text, boolean);

create function public.post_bounty(p_name text, p_multiplier real, p_area text, p_surge boolean default false,
                                   p_budget integer default null, p_danger boolean default false) returns json
language plpgsql security definer set search_path = '' as $$
declare
  g extensions.geometry := extensions.st_geomfromtext(p_area, 4326);
  c extensions.geometry;
  core extensions.geometry;
  b public.bounties;
begin
  if not extensions.st_isvalid(g) then raise exception 'invalid polygon' using errcode = '22023'; end if;
  if p_danger and p_surge then
    c := extensions.st_centroid(g);
    core := extensions.st_translate(
      extensions.st_scale(extensions.st_translate(g, -extensions.st_x(c), -extensions.st_y(c)), 0.4, 0.4),
      extensions.st_x(c), extensions.st_y(c));
  end if;
  insert into public.bounties (name, multiplier, area, buyer, surge, budget_points, danger_area)
  values (p_name, p_multiplier, g::extensions.geography, 'Dashboard', p_surge, p_budget, core::extensions.geography)
  returning * into b;
  if p_surge then  -- same shape as the seeded Arts District storm quest
    insert into public.quests (title, description, target_count, bounty_id, reward_points, reward_xp, ends_at)
    values ('Storm sweep: ' || b.name, 'Document 2 storm-damaged structures in ' || b.name || '.', 2, b.id, 200, 80,
            now() + interval '3 days');
  end if;
  return json_build_object('id', b.id, 'name', b.name, 'multiplier', b.multiplier, 'surge', b.surge,
                           'budget_points', b.budget_points, 'danger', b.danger_area is not null);
end $$;

-- Same as *_surge.sql plus budget, spend and danger core; exhausted bounties drop off like ended ones.
create or replace function public.active_bounties() returns json language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(json_build_object('id', b.id, 'name', b.name, 'multiplier', b.multiplier, 'surge', b.surge,
                                             'budget_points', b.budget_points, 'spent_points', public.bounty_spent(b.id),
                                             'area', extensions.st_asgeojson(b.area)::json,
                                             'danger_area', extensions.st_asgeojson(b.danger_area)::json) order by b.created_at), '[]'::json)
  from public.bounties b
  where public.bounty_live(b)
$$;

-- ── Map read model: − exhausted bounties ───────────────────────────────────────────────────────────────────
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
    ), '[]'::json)
  )
$$;

-- ── Redemption (§6.6; fulfilment mocked for the demo) ──────────────────────────────────────────────────────
-- cash_cost_cents = what one redemption costs FaultLine. Partner offers are 0: the merchant funds the reward to
-- win the visit (the CRED model), which is why they're cheaper in points and why partners pay us.
create table public.reward_catalog (
  sku text primary key,
  title text not null,
  detail text not null,
  kind text not null check (kind in ('gift_card', 'partner_offer', 'donation')),
  cost_points integer not null check (cost_points > 0),
  cash_cost_cents integer not null check (cash_cost_cents >= 0),
  partner text,
  active boolean not null default true,
  sort integer not null default 0
);
alter table public.reward_catalog enable row level security;

create table public.redemptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id),
  sku text not null references public.reward_catalog (sku),
  cost_points integer not null,
  code text not null,
  created_at timestamptz not null default now()
);
alter table public.redemptions enable row level security;

-- Brand-neutral placeholders (MASTER §7.5): no real merchant names or logos without rights.
insert into public.reward_catalog (sku, title, detail, kind, cost_points, cash_cost_cents, partner, sort) values
  ('partner-coffee', 'Free coffee', 'Any size drip coffee at a partner café.', 'partner_offer', 150, 0, 'Partner café', 10),
  ('partner-bike', '20% off a bike tune-up', 'At a neighborhood partner bike shop.', 'partner_offer', 100, 0, 'Partner bike shop', 20),
  ('partner-lunch', '2-for-1 lunch', 'Weekday lunch at a partner restaurant.', 'partner_offer', 300, 0, 'Partner restaurant', 30),
  ('gift-5', '$5 gift card', 'Choose from 100+ brands. Code arrives by email.', 'gift_card', 500, 500, null, 40),
  ('gift-10', '$10 gift card', 'Choose from 100+ brands. Code arrives by email.', 'gift_card', 1000, 1000, null, 50),
  ('gift-25', '$25 gift card', 'Choose from 100+ brands. Code arrives by email.', 'gift_card', 2500, 2500, null, 60),
  ('donate-fixit', 'Give $5 to the neighborhood fix-it fund', 'Pooled toward small repairs the city hasn''t scheduled.', 'donation', 500, 500, null, 70);

create function public.rewards_catalog() returns json language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'items', coalesce((select json_agg(json_build_object(
        'sku', c.sku, 'title', c.title, 'detail', c.detail, 'kind', c.kind, 'cost_points', c.cost_points,
        'partner', c.partner) order by c.sort, c.cost_points)
      from public.reward_catalog c where c.active), '[]'::json),
    'severity_points', json_build_array(public.severity_points(1), public.severity_points(2), public.severity_points(3),
                                        public.severity_points(4), public.severity_points(5)),
    'points_per_dollar', 100)
$$;

-- Spends settled points only. One redemption at a time per player (advisory lock) so a double tap can't overspend.
create function public.redeem_reward(p_sku text) returns json language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  item public.reward_catalog;
  balance integer;
  code text;
begin
  if me is null then raise exception 'sign in required' using errcode = '28000'; end if;
  select * into item from public.reward_catalog where sku = p_sku and active;
  if not found then raise exception 'reward not found' using errcode = 'P0002'; end if;
  perform pg_advisory_xact_lock(hashtextextended(me::text, 0));
  select coalesce(sum(amount), 0) into balance from public.point_ledger
  where user_id = me and currency = 'points' and settles_at <= now();
  if balance < item.cost_points then
    return json_build_object('ok', false, 'balance', balance, 'error',
      format('You need %s more settled points for this.', item.cost_points - balance));
  end if;
  code := 'FL-' || upper(substr(md5(gen_random_uuid()::text), 1, 8));  -- ponytail: mock code; real one comes from the gift-card API
  insert into public.redemptions (user_id, sku, cost_points, code) values (me, item.sku, item.cost_points, code);
  insert into public.point_ledger (user_id, currency, amount, kind, settles_at, note)
  values (me, 'points', -item.cost_points, 'redeem', now(), item.title);
  return json_build_object('ok', true, 'code', code, 'title', item.title, 'cost_points', item.cost_points,
                           'balance', balance - item.cost_points);
end $$;

revoke execute on function public.zone_inputs, public.award_report, public.bounty_spent, public.bounty_live,
  public.post_bounty, public.active_bounties, public.rewards_catalog, public.redeem_reward from public, anon, authenticated;
grant execute on function public.rewards_catalog, public.redeem_reward to authenticated;
