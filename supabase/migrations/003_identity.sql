-- 003_identity.sql
-- Identity. Authentication is Google and Apple only (ADR 6, constitution rule 18).

-- ---------------------------------------------------------------------------
-- users
-- Created the moment someone signs in with Google or Apple, so phone_number has to be
-- nullable at the column level. The real rule is encoded in the check constraint: a
-- COMPLETED profile always has a phone number.
--
--   profile_completed_at null, phone_number null  -> can browse, CANNOT order
--   profile_completed_at set,   phone_number set   -> can order
--
-- id has NO default on purpose. `default auth.users(id)` is illegal: Postgres rejects a
-- column reference in a DEFAULT expression (ERROR 0A000). The id arrives from the
-- on_auth_user_created trigger below, and RLS compares it to auth.uid() on every read.
-- ---------------------------------------------------------------------------
create table users (
  id                   uuid primary key references auth.users(id) on delete cascade,
  phone_number         text unique,                  -- E.164, e.g. +201xxxxxxxxx
  email                text,                         -- carried from the OAuth provider, not a credential
  first_name           text,
  last_name            text,
  avatar_path          text,                         -- R2 path only, never a URL or bytes
  preferred_language   text not null default 'ar' check (preferred_language in ('ar','en')),
  country_code         char(2) not null default 'EG',
  profile_completed_at timestamptz,
  is_active            boolean not null default true,
  last_seen_at         timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  deleted_at           timestamptz,

  constraint profile_phone_required
    check (profile_completed_at is null or phone_number is not null)
);
create index on users (last_seen_at desc) where is_active and profile_completed_at is not null;

-- ---------------------------------------------------------------------------
-- user_roles
-- Many-to-many, not a column on users: a rider is frequently also a customer, and one
-- install serves both roles because the mobile app is role-switched (ADR 15).
-- ---------------------------------------------------------------------------
create table user_roles (
  user_id    uuid not null references users(id) on delete cascade,
  role       text not null check (role in ('customer','rider','admin','support')),
  granted_at timestamptz not null default now(),
  granted_by uuid references users(id),
  primary key (user_id, role)
);
create index on user_roles (role);
create index on user_roles (granted_by) where granted_by is not null;

-- ---------------------------------------------------------------------------
-- user_auth_providers
-- Google and Apple only. No email provider and no phone provider: a phone number is a
-- profile field, not a way in.
-- ---------------------------------------------------------------------------
create table user_auth_providers (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references users(id) on delete cascade,
  provider_type text not null check (provider_type in ('google','apple')),
  provider_id   text not null,                      -- the provider's stable subject id
  linked_at     timestamptz not null default now(),
  unique (provider_type, provider_id)
);
create index on user_auth_providers (user_id);

-- ---------------------------------------------------------------------------
-- addresses
-- ---------------------------------------------------------------------------
create table addresses (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references users(id) on delete cascade,
  label                 text not null default 'home' check (label in ('home','work','other')),
  area_id               uuid references areas(id),
  geohash               text not null,               -- 9 chars is about 150m, for grouping
  geohash_prefix        text not null,               -- 5 chars, for zone lookup
  latitude              numeric(9,6) not null,
  longitude             numeric(9,6) not null,
  area_name             text,
  building              text,
  floor                 text,
  apartment             text,
  landmark              text,                        -- often the only navigable part here
  delivery_instructions text,
  is_default            boolean not null default false,
  last_used_at          timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz
);
create index on addresses (user_id, last_used_at desc) where deleted_at is null;
create index on addresses (geohash_prefix);
create index on addresses (area_id);

create unique index addresses_one_default on addresses (user_id)
  where is_default and deleted_at is null;

-- ---------------------------------------------------------------------------
-- device_tokens
-- app_role is a HINT, NOT A PERMISSION. One device can be both a customer and a rider, so
-- push routing must decide from the order at send time, never from this column (ADR 15).
-- ---------------------------------------------------------------------------
create table device_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references users(id) on delete cascade,
  token        text not null unique,
  platform     text not null check (platform in ('android','ios')),
  app_role     text not null check (app_role in ('customer','rider','admin')),
  app_version  text,
  language     text not null default 'ar',
  last_seen_at timestamptz not null default now(),
  created_at   timestamptz not null default now()
);
create index on device_tokens (user_id, app_role);

-- ---------------------------------------------------------------------------
-- feature_flags
-- Replaces Firebase Remote Config: one source of truth, targetable against real data
-- (ADR 8). Values are public and NON-AUTHORITATIVE. Never a price, fee, permission or
-- secret. See data-model.md for the targeting_rules shape.
-- ---------------------------------------------------------------------------
create table feature_flags (
  id              uuid primary key default gen_random_uuid(),
  flag_key        text not null unique,
  value_type      text not null check (value_type in ('bool','string','number','json')),
  value           jsonb not null,
  targeting_rules jsonb not null default '{}'::jsonb,
  description     text,
  is_active       boolean not null default true,
  updated_at      timestamptz not null default now(),
  updated_by      uuid references auth.users(id)
);
create index on feature_flags (updated_by) where updated_by is not null;

-- ---------------------------------------------------------------------------
-- Sign-in provisioning
--
-- A users row is created the instant someone authenticates with Google or Apple, with
-- profile_completed_at NULL so the app routes them to the completion screen. This is what
-- makes "can browse but cannot order" true before the app has even loaded.
--
-- The 'customer' role is granted to every authenticated user because customer is the base
-- role: anyone can browse and order. Additional roles are granted explicitly, never
-- inherited. This trigger must be SECURITY DEFINER because it writes on behalf of
-- supabase_auth_admin, and search_path is pinned to '' so a shadowing object in public
-- cannot hijack auth.users (data-model.md 13.2).
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.users (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;

  insert into public.user_roles (user_id, role)
  values (new.id, 'customer')
  on conflict (user_id, role) do nothing;

  return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
