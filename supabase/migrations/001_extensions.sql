-- 001_extensions.sql
-- Extensions. Postgres 17, Supabase project erxxsebcqqcpkipzcdhg.
--
-- Rule: migrations 001-022 run against an EMPTY database, so plain CREATE INDEX is correct
-- and CREATE INDEX CONCURRENTLY would fail (the runner wraps the file in a transaction).
-- See data-model.md 15.1.
--
-- postgis is installed because it is available and cheap, but nothing in this schema uses it.
-- Area matching is geohash-prefix plus a haversine distance, which keeps the hot query to a
-- B-tree lookup instead of a GiST scan. Do not add a spatial dependency without an ADR.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;
create extension if not exists btree_gist with schema extensions;
create extension if not exists unaccent with schema extensions;

-- Optional partition management for the four prune-target tables (data-model.md 14.1).
create extension if not exists pg_partman with schema extensions;
