-- "Your report got fixed": buyers mark reports fixed (buyer Edge Function / web/dashboard.html),
-- the reporter gets a bonus and a local notification the next time the app checks my_fixes().

alter table public.reports add column fixed_at timestamptz, add column fixed_note text;

alter table public.point_ledger drop constraint point_ledger_kind_check,
  add constraint point_ledger_kind_check check (kind in ('earn', 'quest', 'redeem', 'clawback', 'fix_bonus'));

-- Idempotent: a second call returns already_fixed and pays nothing. Rejected reports can't be fixed.
create function public.mark_report_fixed(p_report uuid, p_note text default null) returns json
language plpgsql security definer set search_path = '' as $$
declare
  r public.reports;
  bonus constant integer := 25;  -- ponytail: flat bonus; scale by severity if buyers fund it
begin
  update public.reports set fixed_at = now(), fixed_note = nullif(trim(p_note), '')
  where id = p_report and fixed_at is null and status <> 'rejected'
  returning * into r;
  if not found then
    select * into r from public.reports where id = p_report;
    if not found then raise exception 'report not found' using errcode = 'P0002'; end if;
    return json_build_object('id', r.id, 'fixed_at', r.fixed_at, 'already_fixed', r.fixed_at is not null, 'bonus', 0);
  end if;
  if r.user_id is not null then
    insert into public.point_ledger (user_id, report_id, currency, amount, kind, settles_at, note, demo)
    values (r.user_id, r.id, 'points', bonus, 'fix_bonus', now(),
            'Fixed: ' || replace(coalesce(r.primary_type, 'damage'), '_', ' '), r.demo);
  end if;
  return json_build_object('id', r.id, 'fixed_at', r.fixed_at, 'already_fixed', false,
                           'bonus', case when r.user_id is null then 0 else bonus end);
end $$;

-- The signed-in player's reports fixed in the last 30 days (the app notifies once per id).
create function public.my_fixes() returns json language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(json_build_object('id', id, 'primary_type', primary_type, 'fixed_at', fixed_at,
                                             'fixed_note', fixed_note) order by fixed_at desc), '[]'::json)
  from public.reports
  where user_id = auth.uid() and fixed_at > now() - interval '30 days'
$$;

revoke execute on function public.mark_report_fixed, public.my_fixes from public, anon, authenticated;
grant execute on function public.my_fixes to authenticated;

-- map_data: same as 20260925010000_map.sql plus fixed_at on each report.
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
        select bo.id, bo.name, bo.multiplier,
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
