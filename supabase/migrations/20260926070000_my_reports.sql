-- Profile: the signed-in player's last 50 reports plus the counts behind their badges (CLAUDE.md §6.5, MASTER.md §5).
-- Own RPC rather than more game_state: Profile is the only reader, and game_state is polled every 30 s.
-- Badges are derived in the app (ios/Mend/Features/Profile/MyReports.swift) from these counts; the streak comes from the report dates there.
-- A report counts toward badges when it earned points or is waiting on a reviewer (rejected and danger-zone reports don't).
-- points = what the report itself earned (reports.points_pending, set by award_report); the fix bonus is in the ledger.
-- ponytail: surge = inside a surge bounty that was active when the report was filed; recompute if bounties get edited.
create function public.my_reports() returns json language plpgsql stable security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'sign in required' using errcode = '28000'; end if;
  return (
    with mine as (
      select r.*, exists (select 1 from public.bounties b
                          where b.surge and r.geom is not null and extensions.st_intersects(b.area, r.geom)
                            and b.starts_at <= r.created_at and (b.ends_at is null or b.ends_at > r.created_at)) as in_surge,
             (r.status <> 'rejected' and (r.points_pending > 0 or r.status = 'review')) as counted
      from public.reports r where r.user_id = me
    )
    select json_build_object(
      'reports', coalesce((
        select json_agg(json_build_object(
          'id', m.id, 'primary_type', m.primary_type, 'severity', m.severity, 'status', m.status,
          'asset_name', m.asset_name, 'is_first_finder', m.is_first_finder, 'points', m.points_pending,
          'created_at', m.created_at, 'fixed_at', m.fixed_at, 'in_surge', m.in_surge) order by m.created_at desc)
        from (select * from mine order by created_at desc limit 50) m
      ), '[]'::json),
      'stats', json_build_object(
        'verified', (select count(*) from mine where counted),
        'first_finds', (select count(*) from mine where counted and is_first_finder),
        'legendary', (select count(*) from mine where counted and severity = 5),
        'surge', (select count(*) from mine where counted and in_surge),
        'fixed', (select count(*) from mine where status <> 'rejected' and fixed_at is not null),
        'quests', (select count(distinct quest_id) from public.point_ledger
                   where user_id = me and kind = 'quest' and currency = 'points'))
    )
  );
end $$;

revoke execute on function public.my_reports from public, anon, authenticated;
grant execute on function public.my_reports to authenticated; -- anonymous players are 'authenticated' too
