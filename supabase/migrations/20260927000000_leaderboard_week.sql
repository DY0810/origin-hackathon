-- game_state: same as 20260926050000_danger_zones.sql, but the leaderboard week starts Monday 00:00 in Los Angeles,
-- not UTC (UTC Monday is Sunday 17:00 PDT, so the board went to 0 on demo night).
-- ponytail: one fixed market timezone; per-player timezone when we launch a second metro.
create or replace function public.game_state() returns json language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  xp integer;
  lvl integer;
  week_start timestamptz := date_trunc('week', now() at time zone 'America/Los_Angeles') at time zone 'America/Los_Angeles';
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
