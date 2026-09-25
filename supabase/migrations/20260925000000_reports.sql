-- Reports verified server-side by the verify-report Edge Function (CLAUDE.md §7.3, §7.4).
create extension if not exists postgis with schema extensions;

create table public.reports (
  id uuid primary key,
  created_at timestamptz not null default now(),
  image_path text not null,
  source text not null check (source in ('camera', 'library')),
  latitude double precision,
  longitude double precision,
  accuracy_m double precision,
  heading double precision,
  captured_at timestamptz,
  geom extensions.geography(point, 4326) generated always as (
    case when latitude is not null and longitude is not null
      then extensions.st_setsrid(extensions.st_makepoint(longitude, latitude), 4326)::extensions.geography
    end
  ) stored,
  note text,
  suggested_types text[] not null default '{}',           -- on-device model's suggestion, for comparison
  status text not null check (status in ('accepted', 'review', 'rejected')),
  is_damage boolean not null,
  damage_types text[] not null default '{}',
  primary_type text,
  severity smallint check (severity between 1 and 5),
  confidence real,
  explanation text,
  immediate_danger boolean not null default false,
  points_pending integer not null default 0,
  model text not null
);

create index reports_geom_idx on public.reports using gist (geom);
create index reports_created_at_idx on public.reports (created_at desc);

-- Only the Edge Function (service role) reads/writes; clients get nothing directly.
alter table public.reports enable row level security;

insert into storage.buckets (id, name, public) values ('report-photos', 'report-photos', false);
