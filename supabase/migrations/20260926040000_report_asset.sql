-- The asset the reporter confirmed on capture (CLAUDE.md §7.2, asset-lookup Edge Function). Written only by verify-report,
-- which validates and truncates it. osm_id is "node/123" / "way/456"; null for a reporter-named or unknown asset.
-- ponytail: plain columns on reports; an assets table (geometry, criticality, condition history) when the inventory is real.
alter table public.reports
  add column asset_kind text,
  add column asset_name text,
  add column asset_osm_id text;
