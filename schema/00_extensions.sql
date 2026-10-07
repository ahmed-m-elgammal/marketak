-- =============================================================================
-- 00_extensions.sql
-- Extensions installed in the live database.
-- Source: pg_extension (read via Supabase MCP on the running project).
-- =============================================================================

create extension if not exists "uuid-ossp" with schema extensions version '1.1';
create extension if not exists pgcrypto with schema extensions version '1.3';
create extension if not exists btree_gist with schema extensions version '1.7';
create extension if not exists pg_trgm with schema extensions version '1.6';
create extension if not exists unaccent with schema extensions version '1.1';
create extension if not exists pg_stat_statements with schema extensions version '1.11';
create extension if not exists pg_cron with schema extensions version '1.6.4';
create extension if not exists pg_partman with schema extensions version '5.3.1';
create extension if not exists pgtap with schema extensions version '1.3.3';
create extension if not exists supabase_vault with schema vault version '0.3.1';