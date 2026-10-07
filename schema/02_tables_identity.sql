-- =============================================================================
-- 02_tables_identity.sql
-- Users, roles, identity providers, addresses and device tokens.
-- `public.users.id` is a 1:1 mirror of `auth.users.id`; Supabase Auth is the
-- identity system, this table is the profile.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- users: application profile. `profile_completed_at IS NULL` means the account
-- may browse but may not order.
-- -----------------------------------------------------------------------------
create table public.users
(
  id uuid not null,
  phone_number text,
  email text,
  first_name text,
  last_name text,
  avatar_path text,
  preferred_language text not null default 'ar'::text,
  country_code character(2) not null default 'EG'::bpchar,
  profile_completed_at timestamp with time zone,
  is_active boolean not null default true,
  last_seen_at timestamp with time zone,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  deleted_at timestamp with time zone,

  constraint profile_phone_required check CHECK (((profile_completed_at IS NULL) OR (phone_number IS NOT NULL))),
  constraint users_phone_number_key unique UNIQUE (phone_number),
  constraint users_pkey primary key PRIMARY KEY (id),
  constraint users_preferred_language_check check CHECK ((preferred_language = ANY (ARRAY['ar'::text, 'en'::text])))
);

-- -----------------------------------------------------------------------------
-- user_roles: additive role grants. Revocation is soft (revoked_at), so the
-- row remains as history.
-- -----------------------------------------------------------------------------
create table public.user_roles
(
  user_id uuid not null,
  role text not null,
  granted_at timestamp with time zone not null default now(),
  granted_by uuid,
  revoked_at timestamp with time zone,

  constraint user_roles_pkey primary key PRIMARY KEY (user_id, role),
  constraint user_roles_role_check check CHECK ((role = ANY (ARRAY['customer'::text, 'rider'::text, 'admin'::text, 'support'::text])))
);

-- -----------------------------------------------------------------------------
-- user_auth_providers: links a Supabase Auth identity to a Google or Apple
-- provider id. No passwords, no email login, no phone OTP.
-- -----------------------------------------------------------------------------
create table public.user_auth_providers
(
  id uuid not null default gen_random_uuid(),
  user_id uuid not null,
  provider_type text not null,
  provider_id text not null,
  linked_at timestamp with time zone not null default now(),
  deleted_at timestamp with time zone,

  constraint user_auth_providers_pkey primary key PRIMARY KEY (id),
  constraint user_auth_providers_provider_type_check check CHECK ((provider_type = ANY (ARRAY['google'::text, 'apple'::text]))),
  constraint user_auth_providers_provider_type_provider_id_key unique UNIQUE (provider_type, provider_id)
);

-- -----------------------------------------------------------------------------
-- addresses: saved delivery addresses. `geohash` is the full-precision hash,
-- `geohash_prefix` the area-resolution prefix. `area_id` is denormalised so
-- fee lookup does not need to re-resolve geo on every quote.
-- -----------------------------------------------------------------------------
create table public.addresses
(
  id uuid not null default gen_random_uuid(),
  user_id uuid not null,
  label text not null default 'home'::text,
  area_id uuid,
  geohash text not null,
  geohash_prefix text not null,
  latitude numeric(9,6) not null,
  longitude numeric(9,6) not null,
  area_name text,
  building text,
  floor text,
  apartment text,
  landmark text,
  delivery_instructions text,
  is_default boolean not null default false,
  last_used_at timestamp with time zone,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  deleted_at timestamp with time zone,

  constraint addresses_label_check check CHECK ((label = ANY (ARRAY['home'::text, 'work'::text, 'other'::text]))),
  constraint addresses_pkey primary key PRIMARY KEY (id)
);

-- -----------------------------------------------------------------------------
-- device_tokens: push registration per app role. One token row per device;
-- `token` is globally unique so a reinstall moves the row rather than
-- duplicating it.
-- -----------------------------------------------------------------------------
create table public.device_tokens
(
  id uuid not null default gen_random_uuid(),
  user_id uuid not null,
  token text not null,
  platform text not null,
  app_role text not null,
  app_version text,
  language text not null default 'ar'::text,
  last_seen_at timestamp with time zone not null default now(),
  created_at timestamp with time zone not null default now(),

  constraint device_tokens_app_role_check check CHECK ((app_role = ANY (ARRAY['customer'::text, 'rider'::text, 'admin'::text]))),
  constraint device_tokens_pkey primary key PRIMARY KEY (id),
  constraint device_tokens_platform_check check CHECK ((platform = ANY (ARRAY['android'::text, 'ios'::text]))),
  constraint device_tokens_token_key unique UNIQUE (token)
);