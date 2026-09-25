-- Bounty zones + read model for the map (CLAUDE.md §6.4, design-system/MASTER.md §7.3).

-- Buyer-funded coverage areas. The map-data function turns each polygon into H3 cells (res 9).
create table public.bounties (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  multiplier real not null check (multiplier between 1 and 5),
  area extensions.geography(polygon, 4326) not null,
  buyer text,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  created_at timestamptz not null default now()
);
create index bounties_area_idx on public.bounties using gist (area);
alter table public.bounties enable row level security;

-- Seeded demo rows are flagged so they can be removed in one statement: delete from reports where demo;
alter table public.reports add column demo boolean not null default false;

-- Everything the map needs inside a bounding box, safe fields only (no notes, photos or confidence).
-- Called by the map-data Edge Function with the service role; not exposed to clients directly.
create function public.map_data(min_lng double precision, min_lat double precision, max_lng double precision, max_lat double precision)
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
        select rep.id, rep.latitude as lat, rep.longitude as lng, rep.severity, rep.primary_type, rep.status, rep.created_at
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

revoke execute on function public.map_data from public, anon, authenticated;
