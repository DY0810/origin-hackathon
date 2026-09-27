-- Sponsored campaigns (CLAUDE.md §9.1, docs/surge-and-rewards.md §5): a brand pays per verified store visit.
-- Player loop: report a real issue within radius_m of a participating store → check in at the store (≤ 75 m)
-- → get the brand's offer code (+ optional bonus points the brand bought). The sponsor is billed per check-in;
-- the report made on the way is still ordinary condition data we sell to buyers.

alter table public.point_ledger drop constraint point_ledger_kind_check,
  add constraint point_ledger_kind_check check (kind in ('earn', 'quest', 'redeem', 'clawback', 'fix_bonus', 'campaign'));

create table public.campaigns (
  id uuid primary key default gen_random_uuid(),
  sponsor text not null,
  title text not null,
  offer text not null,                -- what the player gets at the till, funded by the sponsor
  detail text,
  bonus_points integer not null default 0 check (bonus_points between 0 and 1000),
  price_per_visit_cents integer not null check (price_per_visit_cents > 0),
  point_price_cents integer not null default 125 check (point_price_cents >= 100), -- sponsor's price per 100 bonus points
  max_visits integer not null check (max_visits > 0),
  radius_m integer not null default 300 check (radius_m between 50 and 1000),
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  demo boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.campaigns enable row level security;

create table public.campaign_stores (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.campaigns (id) on delete cascade,
  name text not null,
  location extensions.geography(point, 4326) not null
);
create index campaign_stores_location_idx on public.campaign_stores using gist (location);
create index campaign_stores_campaign_idx on public.campaign_stores (campaign_id);
alter table public.campaign_stores enable row level security;

-- One verified visit = one billable event. One per player per store per campaign.
create table public.campaign_visits (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.campaigns (id) on delete cascade,
  store_id uuid not null references public.campaign_stores (id) on delete cascade,
  user_id uuid not null references public.profiles (id),
  report_id uuid not null references public.reports (id),
  code text not null unique,
  billed_cents integer not null,
  checked_in_at timestamptz not null default now(),
  redeemed_at timestamptz,
  unique (campaign_id, store_id, user_id)
);
create index campaign_visits_campaign_idx on public.campaign_visits (campaign_id);
alter table public.campaign_visits enable row level security;

create function public.campaign_visit_count(p_campaign uuid) returns integer language sql stable set search_path = '' as $$
  select count(*)::integer from public.campaign_visits where campaign_id = p_campaign
$$;

create function public.campaign_live(c public.campaigns) returns boolean language sql stable set search_path = '' as $$
  select c.starts_at <= now() and c.ends_at > now() and public.campaign_visit_count(c.id) < c.max_visits
$$;

-- What the sponsor pays for one verified visit: the visit fee + the bonus points they bought, at their point price.
create function public.campaign_visit_price(c public.campaigns) returns integer language sql immutable as $$
  select c.price_per_visit_cents + ceil(c.bonus_points * c.point_price_cents / 100.0)::integer
$$;

-- Inside a live danger core (*_surge_pricing_rewards.sql): no campaigns there, ever.
create function public.in_danger(p extensions.geography) returns boolean language sql stable set search_path = '' as $$
  select exists (select 1 from public.bounties d
                 where d.danger_area is not null and public.bounty_live(d) and extensions.st_intersects(d.danger_area, p))
$$;

-- The report that qualifies a player at a store: their own verified (accepted or in review), non-repeat report
-- within radius_m of the store since the campaign started. Most recent first.
create function public.campaign_qualifying_report(p_user uuid, c public.campaigns, s public.campaign_stores) returns uuid
language sql stable set search_path = '' as $$
  select r.id from public.reports r
  where r.user_id = p_user and r.status in ('accepted', 'review') and r.finder is distinct from 'repeat'
    and r.created_at >= c.starts_at and r.geom is not null and extensions.st_dwithin(r.geom, s.location, c.radius_m)
  order by r.created_at desc limit 1
$$;

-- ── Map (anonymous, via map-data): sponsored stops in a bounding box ───────────────────────────────────────
create function public.campaign_stops(min_lng double precision, min_lat double precision, max_lng double precision, max_lat double precision)
returns json language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(json_build_object(
      'id', s.id, 'campaign_id', c.id, 'name', s.name, 'title', c.title, 'sponsor', c.sponsor, 'offer', c.offer,
      'bonus_points', c.bonus_points, 'radius_m', c.radius_m,
      'lat', extensions.st_y(s.location::extensions.geometry), 'lng', extensions.st_x(s.location::extensions.geometry))), '[]'::json)
  from public.campaign_stores s join public.campaigns c on c.id = s.campaign_id
  where public.campaign_live(c) and not public.in_danger(s.location)
    and extensions.st_intersects(s.location, extensions.st_makeenvelope(min_lng, min_lat, max_lng, max_lat, 4326)::extensions.geography)
$$;

-- ── Player ─────────────────────────────────────────────────────────────────────────────────────────────────
-- Live campaigns with each store's state for the signed-in player: qualified (has a report nearby) and their visit.
create function public.campaign_state() returns json language plpgsql stable security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'sign in required' using errcode = '28000'; end if;
  return coalesce((
    select json_agg(json_build_object(
      'id', c.id, 'sponsor', c.sponsor, 'title', c.title, 'offer', c.offer, 'detail', c.detail,
      'bonus_points', c.bonus_points, 'radius_m', c.radius_m, 'ends_at', c.ends_at,
      'visits_left', c.max_visits - public.campaign_visit_count(c.id),
      'stores', (
        select json_agg(json_build_object(
          'id', s.id, 'name', s.name,
          'lat', extensions.st_y(s.location::extensions.geometry), 'lng', extensions.st_x(s.location::extensions.geometry),
          'qualified', public.campaign_qualifying_report(me, c, s) is not null,
          'code', v.code, 'checked_in_at', v.checked_in_at, 'redeemed_at', v.redeemed_at) order by s.name)
        from public.campaign_stores s
        left join public.campaign_visits v on v.store_id = s.id and v.user_id = me
        where s.campaign_id = c.id and not public.in_danger(s.location))
    ) order by c.ends_at)
    from public.campaigns c
    where public.campaign_live(c)
       or exists (select 1 from public.campaign_visits v where v.campaign_id = c.id and v.user_id = me and c.ends_at > now())
  ), '[]'::json);
end $$;

-- Check in at a store. p_lat/p_lng = the phone's current fix (ponytail: trusts the client like the report GPS does;
-- App Attest + consistency checks come with the fraud stack, CLAUDE.md §8). Idempotent: a second call returns the code.
create function public.campaign_check_in(p_store uuid, p_lat double precision, p_lng double precision) returns json
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  s public.campaign_stores;
  c public.campaigns;
  v public.campaign_visits;
  rep uuid;
  dist double precision;
  visit_code text;
  checkin_radius constant integer := 75;
begin
  if me is null then raise exception 'sign in required' using errcode = '28000'; end if;
  select * into s from public.campaign_stores where id = p_store;
  if not found then raise exception 'store not found' using errcode = 'P0002'; end if;
  select * into c from public.campaigns where id = s.campaign_id;
  perform pg_advisory_xact_lock(hashtextextended(c.id::text, 1));  -- one check-in at a time per campaign: max_visits holds

  select * into v from public.campaign_visits where store_id = s.id and user_id = me;
  if found then
    return json_build_object('ok', true, 'already', true, 'code', v.code, 'offer', c.offer, 'title', c.title,
                             'store', s.name, 'bonus_points', 0);
  end if;
  if not public.campaign_live(c) then
    return json_build_object('ok', false, 'error', 'This campaign has ended or every visit has been claimed.');
  end if;
  if public.in_danger(s.location) then
    return json_build_object('ok', false, 'error', 'This store is inside an active danger area. Check-ins are paused.');
  end if;
  if p_lat is null or p_lng is null then
    return json_build_object('ok', false, 'error', 'Turn on location to check in.');
  end if;
  dist := extensions.st_distance(s.location, extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography);
  if dist > checkin_radius then
    return json_build_object('ok', false, 'distance_m', round(dist),
      'error', format('Get within %s m of %s to check in. You''re about %s m away.', checkin_radius, s.name, round(dist)));
  end if;
  rep := public.campaign_qualifying_report(me, c, s);
  if rep is null then
    return json_build_object('ok', false,
      'error', format('First report a real issue within %s m of this store. Then check in.', c.radius_m));
  end if;

  visit_code := upper(substr(md5(gen_random_uuid()::text), 1, 6));
  insert into public.campaign_visits (campaign_id, store_id, user_id, report_id, code, billed_cents)
  values (c.id, s.id, me, rep, visit_code, public.campaign_visit_price(c));
  if c.bonus_points > 0 then
    insert into public.point_ledger (user_id, report_id, currency, amount, kind, settles_at, note)
    values (me, rep, 'points', c.bonus_points, 'campaign', now() + interval '24 hours', 'Sponsored: ' || c.title);
  end if;
  return json_build_object('ok', true, 'already', false, 'code', visit_code, 'offer', c.offer, 'title', c.title,
                           'store', s.name, 'bonus_points', c.bonus_points);
end $$;

-- ── Sponsor (service role, via the buyer Edge Function; input validated in _shared/campaigns.ts) ───────────
-- p: {sponsor, title, offer, detail?, bonus_points, price_per_visit_cents, max_visits, radius_m, days, stores: [{name, lat, lng}]}
create function public.post_campaign(p jsonb) returns json language plpgsql security definer set search_path = '' as $$
declare
  c public.campaigns;
begin
  insert into public.campaigns (sponsor, title, offer, detail, bonus_points, price_per_visit_cents, max_visits, radius_m, ends_at)
  values (p->>'sponsor', p->>'title', p->>'offer', nullif(p->>'detail', ''), (p->>'bonus_points')::integer,
          (p->>'price_per_visit_cents')::integer, (p->>'max_visits')::integer, (p->>'radius_m')::integer,
          now() + make_interval(days => (p->>'days')::integer))
  returning * into c;
  insert into public.campaign_stores (campaign_id, name, location)
  select c.id, st.name, extensions.st_setsrid(extensions.st_makepoint(st.lng, st.lat), 4326)::extensions.geography
  from jsonb_to_recordset(p->'stores') as st(name text, lat double precision, lng double precision);
  return json_build_object('id', c.id, 'title', c.title, 'stores', jsonb_array_length(p->'stores'),
                           'price_per_visit_cents', public.campaign_visit_price(c));
end $$;

-- Live campaigns (and ones that ended in the last 7 days) with the numbers a sponsor is billed on.
create function public.campaign_summary() returns json language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(json_build_object(
      'id', c.id, 'sponsor', c.sponsor, 'title', c.title, 'offer', c.offer, 'live', public.campaign_live(c),
      'ends_at', c.ends_at, 'max_visits', c.max_visits, 'radius_m', c.radius_m, 'bonus_points', c.bonus_points,
      'visit_price_cents', public.campaign_visit_price(c),
      'visits', (select count(*) from public.campaign_visits v where v.campaign_id = c.id),
      'redeemed', (select count(*) from public.campaign_visits v where v.campaign_id = c.id and v.redeemed_at is not null),
      'billed_cents', (select coalesce(sum(billed_cents), 0) from public.campaign_visits v where v.campaign_id = c.id),
      'stores', (select json_agg(json_build_object('id', s.id, 'name', s.name,
                   'lat', extensions.st_y(s.location::extensions.geometry), 'lng', extensions.st_x(s.location::extensions.geometry),
                   'visits', (select count(*) from public.campaign_visits v where v.store_id = s.id)) order by s.name)
                 from public.campaign_stores s where s.campaign_id = c.id)
    ) order by c.created_at desc), '[]'::json)
  from public.campaigns c
  where c.ends_at > now() - interval '7 days'
$$;

-- The till: staff type the player's code. Idempotent; P0002 for a code that doesn't exist.
create function public.redeem_campaign_code(p_code text) returns json language plpgsql security definer set search_path = '' as $$
declare
  v public.campaign_visits;
  c public.campaigns;
  s public.campaign_stores;
  already boolean := false;
begin
  update public.campaign_visits set redeemed_at = now()
  where code = upper(trim(p_code)) and redeemed_at is null returning * into v;
  if not found then
    select * into v from public.campaign_visits where code = upper(trim(p_code));
    if not found then raise exception 'code not found' using errcode = 'P0002'; end if;
    already := true;
  end if;
  select * into c from public.campaigns where id = v.campaign_id;
  select * into s from public.campaign_stores where id = v.store_id;
  return json_build_object('code', v.code, 'offer', c.offer, 'title', c.title, 'store', s.name,
                           'already_redeemed', already, 'redeemed_at', v.redeemed_at);
end $$;

create function public.end_campaign(p_id uuid) returns json language plpgsql security definer set search_path = '' as $$
begin
  update public.campaigns set ends_at = now() where id = p_id and ends_at > now();
  if not found then raise exception 'campaign not found' using errcode = 'P0002'; end if;
  return json_build_object('id', p_id, 'ended', true);
end $$;

revoke execute on function public.campaign_visit_count, public.campaign_live, public.in_danger,
  public.campaign_qualifying_report, public.campaign_stops, public.campaign_state, public.campaign_check_in,
  public.post_campaign, public.campaign_summary, public.redeem_campaign_code, public.end_campaign
  from public, anon, authenticated;
grant execute on function public.campaign_state, public.campaign_check_in to authenticated;
