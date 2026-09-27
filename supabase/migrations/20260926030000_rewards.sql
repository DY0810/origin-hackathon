-- Mocked gift-card redemption (CLAUDE.md §6.6): a fixed catalog, redeem() spends SETTLED points through a
-- negative 'redeem' ledger row and hands back a fake code. No gift-card API is called.
-- Rate: points_per_dollar() (CLAUDE.md §14 keeps the real rate open). Prices are stored in dollars and derived.
-- ponytail: mock codes; swap the code line for a Tremendous / Tango Card order when payouts are real.

create table public.reward_catalog (
  sku text primary key,
  name text not null,
  dollars integer not null check (dollars > 0),
  sort integer not null default 0
);
alter table public.reward_catalog enable row level security;

insert into public.reward_catalog (sku, name, dollars, sort) values
  ('amazon-5', '$5 Amazon gift card', 5, 1),
  ('target-5', '$5 Target gift card', 5, 2),
  ('starbucks-10', '$10 Starbucks gift card', 10, 3),
  ('doordash-10', '$10 DoorDash gift card', 10, 4);

create table public.redemptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id),
  sku text not null references public.reward_catalog (sku),
  points integer not null check (points > 0),
  status text not null default 'sent' check (status in ('sent')),
  code text not null,
  created_at timestamptz not null default now()
);
create index redemptions_user_idx on public.redemptions (user_id, created_at desc);
alter table public.redemptions enable row level security;

create function public.points_per_dollar() returns integer language sql immutable set search_path = '' as $$ select 100 $$;

-- Smallest redemption allowed (§6.6 minimum threshold): $5, also the cheapest catalog item today.
create function public.min_redeem_points() returns integer language sql immutable set search_path = '' as $$
  select 5 * public.points_per_dollar()
$$;

-- Spends settled points on one catalog item. The profile row lock serializes a player's redeems,
-- so a double tap can't spend the same balance twice.
create function public.redeem(p_sku text) returns json language plpgsql security definer set search_path = '' as $$
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
  price := item.dollars * public.points_per_dollar();
  perform public.ensure_profile(me);
  perform 1 from public.profiles where id = me for update;

  select coalesce(sum(amount), 0) into balance from public.point_ledger
  where user_id = me and currency = 'points' and settles_at <= now();
  if balance < greatest(price, public.min_redeem_points()) then
    raise exception 'Not enough available points. Pending points count once they settle.' using errcode = 'FL001';
  end if;

  mock_code := 'FL-' || substr(mock_code, 1, 4) || '-' || substr(mock_code, 5, 4);
  insert into public.point_ledger (user_id, currency, amount, kind, settles_at, note)
  values (me, 'points', -price, 'redeem', now(), 'Redeemed: ' || item.name);
  insert into public.redemptions (user_id, sku, points, code) values (me, item.sku, price, mock_code);
  return json_build_object('code', mock_code, 'sku', item.sku, 'points', price, 'balance', balance - price);
end $$;

-- game_state: same as 20260925020000_game.sql plus the catalog, past redemptions, min_redeem,
-- and a surge flag on each quest (Quests tab badge dot).
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

revoke execute on function public.redeem, public.min_redeem_points, public.points_per_dollar from public, anon, authenticated;
grant execute on function public.redeem to authenticated; -- anonymous players are 'authenticated' too
