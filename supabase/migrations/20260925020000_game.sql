-- Game layer (CLAUDE.md §6.5, design-system/MASTER.md §9): players, append-only point/XP ledger, quests,
-- weekly leaderboard. Balances are always derived from the ledger, never stored.

-- One player per app install (Supabase anonymous auth user). Demo players have no auth user.
create table public.profiles (
  id uuid primary key,
  handle text not null unique,
  demo boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

alter table public.reports add column user_id uuid references public.profiles (id);
create index reports_user_idx on public.reports (user_id, created_at desc);

create table public.quests (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text not null,
  target_count integer not null check (target_count > 0),
  bounty_id uuid references public.bounties (id) on delete cascade, -- only reports inside this bounty count
  damage_types text[],                                               -- null = any damage type
  reward_points integer not null check (reward_points >= 0),
  reward_xp integer not null check (reward_xp >= 0),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  demo boolean not null default false
);
alter table public.quests enable row level security;

create table public.point_ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id),
  report_id uuid references public.reports (id),
  quest_id uuid references public.quests (id) on delete set null,
  currency text not null check (currency in ('points', 'xp')),
  amount integer not null,
  kind text not null check (kind in ('earn', 'quest', 'redeem', 'clawback')),
  settles_at timestamptz, -- points: spendable once now() >= settles_at; null = held for human review. XP ignores it.
  note text,
  demo boolean not null default false,
  created_at timestamptz not null default now()
);
create index point_ledger_user_idx on public.point_ledger (user_id, created_at desc);
create unique index point_ledger_one_quest_reward on public.point_ledger (user_id, quest_id, currency) where quest_id is not null;
alter table public.point_ledger enable row level security;

-- Append-only: corrections are new rows (clawback), never edits. Demo rows may be deleted for cleanup.
create function public.point_ledger_append_only() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' and old.demo then return old; end if;
  raise exception 'point_ledger is append-only; add a clawback row instead';
end $$;
create trigger point_ledger_append_only before update or delete on public.point_ledger
  for each row execute function public.point_ledger_append_only();

-- Level curve: level n starts at 25·(n-1)² XP (0, 25, 100, 225, 400, 625, …).
create function public.level_for_xp(xp integer) returns integer language sql immutable as $$
  select floor(sqrt(greatest(xp, 0) / 25.0))::integer + 1
$$;

create function public.title_for_level(level integer) returns text language sql immutable as $$
  select case when level >= 8 then 'Chief Engineer' when level >= 5 then 'Structural Sleuth'
              when level >= 3 then 'Inspector' else 'Rookie Spotter' end
$$;

create function public.multiplier_at(p_geom extensions.geography) returns real language sql stable set search_path = '' as $$
  select coalesce(max(b.multiplier), 1)::real from public.bounties b
  where p_geom is not null and extensions.st_intersects(b.area, p_geom)
    and b.starts_at <= now() and (b.ends_at is null or b.ends_at > now())
$$;

create function public.quest_progress(p_user uuid, p_quest public.quests) returns integer language sql stable set search_path = '' as $$
  select count(*)::integer from public.reports r
  left join public.bounties b on b.id = p_quest.bounty_id
  where r.user_id = p_user and r.status in ('accepted', 'review')
    and r.created_at >= p_quest.starts_at and (p_quest.ends_at is null or r.created_at < p_quest.ends_at)
    and (p_quest.bounty_id is null or (r.geom is not null and extensions.st_intersects(b.area, r.geom)))
    and (p_quest.damage_types is null or r.damage_types && p_quest.damage_types)
$$;

create function public.xp_total(p_user uuid) returns integer language sql stable set search_path = '' as $$
  select coalesce(sum(amount), 0)::integer from public.point_ledger where user_id = p_user and currency = 'xp'
$$;

-- Creates the player on first contact with a friendly generated handle.
create function public.ensure_profile(p_user uuid) returns void language plpgsql security definer set search_path = '' as $$
declare
  adjectives text[] := array['Brisk','Keen','Steady','Bold','Quiet','Sharp','Swift','Sunny','Clever','Gritty'];
  nouns text[] := array['Otter','Falcon','Badger','Heron','Lynx','Beaver','Kestrel','Fox','Marten','Wren'];
begin
  if p_user is null or exists (select 1 from public.profiles where id = p_user) then return; end if;
  for attempt in 1..20 loop
    begin
      insert into public.profiles (id, handle) values (p_user,
        adjectives[1 + floor(random() * 10)::int] || ' ' || nouns[1 + floor(random() * 10)::int] || ' ' || (10 + floor(random() * 90)::int));
      return;
    exception when unique_violation then
      if exists (select 1 from public.profiles where id = p_user) then return; end if;
    end;
  end loop;
  raise exception 'could not allocate a handle';
end $$;

-- Rewards for one verified report: zone-multiplied pending points, XP, and any quests it completes.
-- Called once by the verify-report Edge Function (service role) right after the report row is inserted.
create function public.award_report(p_report uuid) returns json language plpgsql security definer set search_path = '' as $$
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
  if r.status = 'rejected' or r.severity is null then
    return json_build_object('base_points', 0, 'multiplier', 1, 'points', 0, 'xp', 0, 'quests_completed', '[]'::json,
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
  loop
    if public.quest_progress(r.user_id, q) >= q.target_count then
      insert into public.point_ledger (user_id, quest_id, currency, amount, kind, settles_at, note) values
        (r.user_id, q.id, 'points', q.reward_points, 'quest', now() + interval '24 hours', q.title),
        (r.user_id, q.id, 'xp', q.reward_xp, 'quest', null, q.title);
      completed := completed || json_build_object('title', q.title, 'reward_points', q.reward_points, 'reward_xp', q.reward_xp);
    end if;
  end loop;

  return json_build_object(
    'base_points', base, 'multiplier', mult, 'points', pts, 'xp', xp,
    'quests_completed', array_to_json(completed),
    'level_before', public.level_for_xp(xp_before), 'level_after', public.level_for_xp(public.xp_total(r.user_id)));
end $$;

-- Everything the Quests / Rewards / Profile tabs show, for the signed-in player.
create function public.game_state() returns json language plpgsql security definer set search_path = '' as $$
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
        'multiplier', b.multiplier, 'area_name', b.name) order by q.ends_at nulls last, q.title)
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
    ), '[]'::json)
  );
end $$;

revoke execute on function public.ensure_profile, public.award_report, public.game_state,
  public.quest_progress, public.xp_total, public.multiplier_at from public, anon, authenticated;
grant execute on function public.game_state to authenticated; -- anonymous players are 'authenticated' too
