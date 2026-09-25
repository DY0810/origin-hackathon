-- Demo map data around USC / downtown LA. Safe to re-run.
-- Remove all demo data: run the delete statements below on their own.
delete from public.point_ledger where demo;
delete from public.profiles where demo;
delete from public.reports where demo;
delete from public.bounties where buyer like 'Demo:%'; -- cascades to their quests
delete from public.quests where demo;

insert into public.bounties (name, multiplier, buyer, area) values
  ('USC campus sidewalks', 1.5, 'Demo: USC Facilities',
   'SRID=4326;POLYGON((-118.2900 34.0170, -118.2800 34.0170, -118.2800 34.0250, -118.2900 34.0250, -118.2900 34.0170))'),
  ('Exposition Park paths & bridges', 2, 'Demo: LA Parks',
   'SRID=4326;POLYGON((-118.2920 34.0080, -118.2800 34.0080, -118.2800 34.0170, -118.2920 34.0170, -118.2920 34.0080))'),
  ('Figueroa corridor', 3, 'Demo: LADOT',
   'SRID=4326;POLYGON((-118.2780 34.0250, -118.2680 34.0250, -118.2680 34.0450, -118.2780 34.0450, -118.2780 34.0250))'),
  ('Storm sweep: Arts District', 5, 'Demo: Metro Insurance',
   'SRID=4326;POLYGON((-118.2400 34.0360, -118.2260 34.0360, -118.2260 34.0480, -118.2400 34.0480, -118.2400 34.0360))');

insert into public.reports (id, image_path, source, latitude, longitude, accuracy_m, status, is_damage, damage_types,
                            primary_type, severity, confidence, explanation, points_pending, model, demo, created_at)
select gen_random_uuid(), 'demo', 'camera', lat, lng, 8, status, true, array[kind], kind, sev, 0.9, 'Demo report', pts,
       'demo-seed', true, now() - (hours || ' hours')::interval
from (values
  (34.0205, -118.2856, 'crack',          2, 'accepted', 25, 3),
  (34.0221, -118.2871, 'spalling',       3, 'accepted', 50, 20),
  (34.0189, -118.2832, 'corrosion',      2, 'accepted', 25, 40),
  (34.0140, -118.2869, 'exposed_rebar',  4, 'accepted', 80, 6),
  (34.0112, -118.2841, 'crack',          1, 'accepted', 10, 70),
  (34.0301, -118.2735, 'pothole',        3, 'accepted', 50, 2),
  (34.0352, -118.2721, 'pothole',        4, 'accepted', 80, 12),
  (34.0405, -118.2702, 'crack',          3, 'accepted', 50, 30),
  (34.0418, -118.2331, 'detachment',     4, 'accepted', 80, 1),
  (34.0433, -118.2302, 'structural_collapse', 5, 'review', 120, 1),
  (34.0397, -118.2355, 'leakage',        2, 'accepted', 25, 5),
  (34.0260, -118.2790, 'efflorescence',  1, 'accepted', 10, 90)
) as v(lat, lng, kind, sev, status, pts, hours);

-- Quests (CLAUDE.md §6.5). Bounty-linked quests only count reports inside that bounty.
insert into public.quests (title, description, target_count, bounty_id, damage_types, reward_points, reward_xp, ends_at, demo)
select v.title, v.description, v.target, b.id, v.types, v.pts, v.xp, now() + v.lasts, true
from (values
  ('First find', 'Report any verified damage.', 1, null, null::text[], 20, 25, interval '30 days'),
  ('Pothole patrol', 'Report 3 potholes anywhere.', 3, null, array['pothole'], 100, 50, interval '7 days'),
  ('Figueroa sweep', 'Report 3 issues along the Figueroa corridor.', 3, 'Figueroa corridor', null, 150, 60, interval '7 days'),
  ('Storm sweep: Arts District', 'Document 2 storm-damaged structures in the Arts District.', 2, 'Storm sweep: Arts District', null, 200, 80, interval '3 days')
) as v(title, description, target, bounty, types, pts, xp, lasts)
left join public.bounties b on b.name = v.bounty;

-- Rival players so the weekly leaderboard isn't empty. Points land this week.
insert into public.profiles (id, handle, demo)
select gen_random_uuid(), h, true
from unnest(array['Keen Heron 31','Gritty Badger 77','Swift Kestrel 12','Sunny Wren 58','Bold Lynx 90','Quiet Marten 24','Clever Fox 66']) as h;

insert into public.point_ledger (user_id, currency, amount, kind, settles_at, note, demo, created_at)
select p.id, c.currency, c.amount, 'earn', case when c.currency = 'points' then now() end, 'demo', true,
       greatest(date_trunc('week', now()), now() - interval '2 days')
from public.profiles p
join (values ('Keen Heron 31', 640), ('Gritty Badger 77', 515), ('Swift Kestrel 12', 430), ('Sunny Wren 58', 310),
             ('Bold Lynx 90', 225), ('Quiet Marten 24', 140), ('Clever Fox 66', 75)) as s(handle, pts) on s.handle = p.handle
cross join lateral (values ('points', s.pts), ('xp', s.pts / 2)) as c(currency, amount)
where p.demo;
