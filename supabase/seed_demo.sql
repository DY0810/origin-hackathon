-- Demo map data around USC / downtown LA. Safe to re-run.
-- Remove: delete from public.reports where demo; delete from public.bounties where buyer like 'Demo:%';
delete from public.reports where demo;
delete from public.bounties where buyer like 'Demo:%';

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
