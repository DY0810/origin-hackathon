-- First finder vs confirmation (CLAUDE.md §6.5, §8 "first finder only once per asset per window"). The first verified
-- report on an asset in 30 days pays full; later ones are confirmations at 40% of base (zone multiplier still applies).
-- reports.is_first_finder is null for reports that earned nothing (rejected, danger zone) and for rows before this migration.

alter table public.reports add column is_first_finder boolean;
create index reports_asset_osm_idx on public.reports (asset_osm_id) where asset_osm_id is not null;

-- award_report: same as 20260926050000_danger_zones.sql, plus first finder / confirmation (first_finder in the result).
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
  first_finder boolean;
begin
  select * into r from public.reports where id = p_report;
  if r.id is null or r.user_id is null then raise exception 'report % missing or has no player', p_report; end if;
  if r.status = 'rejected' or r.severity is null or public.in_danger(r.geom) or (r.source = 'library' and r.geom is null) then
    return json_build_object('base_points', 0, 'multiplier', 1, 'points', 0, 'xp', 0, 'quests_completed', '[]'::json,
      'danger', public.in_danger(r.geom), 'first_finder', null,  -- nothing earned: neither tag
      'level_before', public.level_for_xp(public.xp_total(r.user_id)), 'level_after', public.level_for_xp(public.xp_total(r.user_id)));
  end if;

  -- First finder unless another report that earned something (points, or held for review), older and at most 30 days
  -- before this one, is on the same asset:
  -- same OSM id when both have one, else within 15 m with the same primary type. The OR arms use reports_asset_osm_idx and
  -- reports_geom_idx (r.* are constants here, so the planner can BitmapOr them).
  -- ponytail: two reports of the same asset landing in the same second can both be first finder; lock on the asset if it matters.
  first_finder := not exists (
    select 1 from public.reports o
    where o.id <> r.id and o.status <> 'rejected' and (o.points_pending > 0 or o.status = 'review')
      and o.created_at < r.created_at and o.created_at >= r.created_at - interval '30 days'
      and ((r.asset_osm_id is not null and o.asset_osm_id = r.asset_osm_id)
           or (r.geom is not null and extensions.st_dwithin(o.geom, r.geom, 15) and o.primary_type = r.primary_type
               and (r.asset_osm_id is null or o.asset_osm_id is null))));

  base := (array[10, 25, 50, 80, 120])[r.severity];
  -- Confirmations still pay (they track progression, CLAUDE.md §6.5) but 40%, so re-shooting a known defect isn't a farm.
  -- XP stays full: XP isn't cash, and confirmations are exactly the engagement we want to reward.
  if not first_finder then base := round(base * 0.4); end if;
  if r.source = 'camera' then mult := public.multiplier_at(r.geom); end if; -- library photos have no trustworthy location
  pts := round(base * mult);
  xp := 10 + 5 * r.severity;
  settle := case when r.status = 'accepted' then now() + interval '24 hours' end; -- review: held until a human decides
  xp_before := public.xp_total(r.user_id);

  insert into public.point_ledger (user_id, report_id, currency, amount, kind, settles_at, note) values
    (r.user_id, r.id, 'points', pts, 'earn', settle, coalesce(r.primary_type, 'damage') || case when first_finder then '' else ' · confirmation' end
                                                      || case when mult > 1 then ' · ' || mult || '× zone' else '' end),
    (r.user_id, r.id, 'xp', xp, 'earn', null, null);
  update public.reports set points_pending = pts, is_first_finder = first_finder where id = r.id;

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
    'quests_completed', array_to_json(completed),
    'level_before', public.level_for_xp(xp_before), 'level_after', public.level_for_xp(public.xp_total(r.user_id)));
end $$;
