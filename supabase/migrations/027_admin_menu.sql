-- 027: the admin write surface for the catalog — the second half of "load a merchant and take
-- an order". `026` gave a merchant its geography and identity; this gives it dishes.
--
-- admin-crud-plan.md §6: "`026` and `027` together are the smallest set that lets you load a
-- merchant and take an order."
--
-- ---------------------------------------------------------------------------
-- FUNCTION SHAPE, AND WHY IT IS FIFTEEN FUNCTIONS
-- ---------------------------------------------------------------------------
-- The same six rules from §3 that 026 applies, uniformly, to every function below:
--
--   1. The table name is a LITERAL in the body. Never a parameter.
--   2. p_patch is validated against an explicit key ALLOWLIST. An unknown key is an error.
--   3. private.is_admin() is the FIRST check, after auth only.
--   4. search_path = '' and every name fully qualified.
--   5. One events row per mutation, same transaction, per constitution II.16.
--   6. Every function checks deleted_at on read and refuses to touch a soft-deleted row except
--      through its matching restore.
--
-- Five tables, three operations each: five upserts, five soft deletes, five restores.
--
-- ---------------------------------------------------------------------------
-- WHAT THE SCHEMA DECIDED FOR US, AND TWO PLACES IT DID NOT
-- ---------------------------------------------------------------------------
-- `menu_items.vendor_id` is NOT admin-writable and is not in the allowlist. `sync_menu_item_vendor`
-- is a BEFORE INSERT OR UPDATE trigger that unconditionally overwrites it from the parent
-- category's vendor, so the column is derived. A caller passing `vendor_id` gets UNKNOWN_KEY,
-- which is the truthful answer: there is no code path, in this function or any other, by which
-- that value survives an insert.
--
-- Moving a CATEGORY between vendors is refused outright, not merely unlisted. `sync_menu_item_vendor`
-- recomputes every item's vendor from its category, so re-homing one category silently re-homes
-- all forty of its items to a different merchant's storefront — different rating, different
-- reviews, different payout ledger. That is a data-integrity catastrophe with a plausible UI, so
-- `admin_upsert_menu_category_v1` raises IMMUTABLE_FIELD. Delete and recreate instead.
--
-- The GENERATED columns (`name_normalized`, `name_ar_normalized`, `ingredients_normalized`) are not
-- writable by anyone and are absent from every allowlist, for the same reason 026 omits the vendor
-- ones: the column cannot be set, so claiming to set it would be a lie the caller could act on.
--
-- `vendors.menu_version` is absent too, and that omission is load-bearing rather than tidy. The
-- `trg_bump_v_*` statement triggers from 005b already bump it on every catalog write, which changes
-- the R2 snapshot URL. If an admin could set it directly, the pointer would desynchronise from the
-- catalog — the exact bug 014a fixed for vendor visibility. ADR 22's note that "this plan must not
-- reintroduce the fingerprint mechanism" is honoured the same way: `is_available` and `stock_count`
-- ARE admin-editable, because 017a moved that refusal to quote time, and no fingerprint is touched.
--
-- ---------------------------------------------------------------------------
-- MONEY IS IN PIANTRES, AND ALWAYS WAS
-- ---------------------------------------------------------------------------
-- `menu_items.base_price`, `menu_item_sizes.price` and `option_choices.price_modifier` are integer
-- columns and this file passes integers through untouched. They are minor units — an admin sending
-- `250` means 2.50 EGP, not 250. This file deliberately contains no currency literal and no
-- conversion: constitution I.1 puts the arithmetic in Postgres and this surface stores what it is
-- given. A dashboard that renders "250" as "250 EGP" is a dashboard bug, and one that sends a
-- float here is a rejected insert.
--
-- ---------------------------------------------------------------------------
-- TWO HIDING MECHANISMS, AND WHY THE DELETE FUNCTIONS DIFFER PER TABLE
-- ---------------------------------------------------------------------------
-- This is the finding that shaped this file. `deleted_at` is not honoured uniformly by the catalog
-- read policies, so "soft delete" means something different per table and the delete functions are
-- NOT interchangeable:
--
--   menu_categories     menu_items_read      filters deleted_at  -> deleted_at alone hides it
--   menu_items          menu_items_read      filters deleted_at  -> deleted_at alone hides it
--   menu_item_sizes     does NOT filter      -> is_available is the only lever
--   option_choices      does NOT filter      -> is_available is the only lever
--   item_options        was qual = true      -> had NO lever at all
--
-- So `admin_delete_menu_item_size_v1` and `admin_delete_option_choice_v1` set `is_available = false`
-- as well as `deleted_at`. A delete that set only `deleted_at` on those two tables would have
-- returned success, written its events row, and changed nothing a customer can see.
--
-- RESTORE NEVER RE-PUBLISHES. `admin_restore_*` clears `deleted_at` and nothing else, deliberately,
-- even on the tables where delete set `is_available = false`. Archive is not a covert publish: a
-- vendor who set `is_available = false` on purpose must not find that choice silently reversed by a
-- restore, and an admin who wants a row back on sale says so explicitly. The cost is that a
-- restored row stays invisible until someone publishes it, which is the honest cost of the safety.
--
-- `item_options` was the one table with no mechanism at all, so this migration supplies one:
-- `is_available boolean not null default true`, plus a corrected read policy. Existing rows default
-- to visible, so deploying this changes nothing until an admin writes. The new policy mirrors
-- `menu_item_sizes_read` — own `is_available`, a vendor-staff branch so vendor self-service is not
-- regressed, and an admin branch. See the note beside the policy for why the parent-item check is
-- absent.
--
-- ---------------------------------------------------------------------------
-- PARENTS ARE REFUSED WHILE CHILDREN ARE LIVE
-- ---------------------------------------------------------------------------
-- `admin_delete_menu_category_v1` returns CATEGORY_NOT_EMPTY, `admin_delete_menu_item_v1` returns
-- ITEM_NOT_EMPTY, and `admin_delete_item_option_v1` returns OPTION_NOT_EMPTY. Admin archives
-- children first, then the parent.
--
-- This is not tidiness, it is what makes the policy gap above unreachable. `menu_items_read` does
-- not check the parent category, and `menu_item_sizes_read` / `option_choices_read` do not check the
-- parent item. A soft-deleted parent with live children therefore leaves those children directly
-- readable. Rather than amend three applied read policies for a hole no admin action could reach,
-- the admin surface refuses the state that produces it — so no child can outlive its parent's
-- visibility. Subtrees go dark in reverse order, which is also the order an admin thinks in.
--
-- ---------------------------------------------------------------------------
-- WHY A SIZED ITEM CANNOT BE CREATED IN ONE CALL, AND HOW TO CREATE ONE
-- ---------------------------------------------------------------------------
-- `trg_item_has_sizes` is a DEFERRABLE INITIALLY DEFERRED trigger, so `assert_item_has_sizes` runs
-- at COMMIT, not at the call. Creating a `pricing_mode = 'sized'` item in a transaction of its own
-- therefore fails at commit with `ITEM_SIZED_BUT_NO_SIZES` — correct behaviour, but a confusing one
-- for a caller who expected a clean RPC error.
--
-- On the INSERT path this function raises that error itself, immediately, because a row that was
-- just created provably cannot have sizes yet. On the UPDATE path it deliberately does NOT
-- pre-check: a caller is entitled to add the sizes and flip the mode in one transaction, and a
-- pre-check would forbid a legal ordering. The deferred trigger stays the authority there.
--
-- The canonical order, which works one RPC call at a time:
--
--   1. admin_upsert_menu_item_v1  pricing_mode = 'fixed'      (or 'sized' inside a transaction
--                                                               that also inserts the sizes)
--   2. admin_upsert_menu_item_size_v1, once per size
--   3. admin_upsert_menu_item_v1  pricing_mode = 'sized'      (sizes exist, trigger passes)
--
-- Step 3 is where `menu_item_sizes` rows may be soft-deleted, which is why the delete function
-- below protects the last live size of a sized item: `assert_item_still_sized` counts rows without
-- filtering `deleted_at`, so the schema's own guard does not see a soft delete as a removal.
--
-- ---------------------------------------------------------------------------
-- TWO REFUSALS THAT PREVENT DATA THE CHECKOUT CANNOT HANDLE
-- ---------------------------------------------------------------------------
-- `option_selections_sane` only enforces `max_selections >= min_selections`, which permits
-- `is_required = true` with `max_selections = 0` — a group the customer must choose from and is
-- permitted to choose nothing from. `OPTION_REQUIRED_UNSATISFIABLE` refuses it.
--
-- The same contradiction is reachable without touching that column, by deleting choices until fewer
-- remain than `max_selections` promises, or by raising `max_selections` above the number of live
-- choices. `OPTION_UNSATISFIABLE` refuses both. Together they keep every option satisfiable, which is
-- the difference between an admin mistake caught in the console and an `OPTION_UNAVAILABLE` raised
-- against a customer holding a cart.
--
-- ---------------------------------------------------------------------------
-- SOFT DELETE, NOT DELETE
-- ---------------------------------------------------------------------------
-- `admin_delete_*_v1` sets `deleted_at`. There is deliberately no `admin_hard_delete_v1` and no
-- function in this file that issues a DELETE, and assertion 8 proves it with a negative test.
--
-- Every delete and every restore requires a non-blank reason, because `private.err` aside, a reason
-- is the only thing that makes an archive reviewable after the fact.

-- =============================================================================================
-- 0. The one schema amendment: item_options gains the flag it never had
-- =============================================================================================
-- `menu_item_sizes`, `menu_items` and `option_choices` all carry `is_available`. `item_options`
-- did not, and its SELECT policy was unqualified `true`, which made it the only catalog table where
-- a soft delete was provably a no-op. `not null default true` means no existing row changes
-- visibility when this runs.
alter table public.item_options
  add column if not exists is_available boolean not null default true;

-- The replacement policy mirrors menu_item_sizes_read: own is_available, a vendor-staff branch, and
-- an admin branch. The vendor branch is new and necessary — the old policy granted every
-- authenticated user blanket visibility, so removing it without adding this would have taken
-- visibility away from the vendor's own staff.
--
-- There is deliberately no `exists (... menu_items ...)` parent check, matching the two sibling
-- policies. The state that would need it is unreachable, because admin_delete_menu_item_v1 refuses
-- while sizes or options are live.
drop policy if exists item_options_read on public.item_options;
create policy item_options_read on public.item_options
  for select to authenticated
  using (
       ( item_options.is_available and item_options.deleted_at is null )
    or exists ( select 1 from public.item_options io
                  join public.menu_items mi on mi.id = io.item_id
                 where io.id = item_options.id
                   and mi.vendor_id in ( select private.vendor_ids_for(( select auth.uid() )) ) )
    or ( select private.is_admin() )
  );

-- =============================================================================================
-- 1. menu_categories
-- =============================================================================================
create or replace function public.admin_upsert_menu_category_v1(p_patch jsonb, p_id uuid default null)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_id uuid;
  v_allowed constant text[] := array['vendor_id','name','name_ar','description','display_order','is_available'];
  v_unknown text;
  v_exists boolean;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'menu categories are admin only'); end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;

  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_patch) as k
   where not (k = any (v_allowed));
  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not a menu_categories column: ' || v_unknown);
  end if;

  if p_id is null then
    if (p_patch->>'vendor_id') is null then
      perform private.err('KEY_REQUIRED', 'vendor_id is required to create a category');
    end if;
    if (p_patch->>'name') is null then
      perform private.err('KEY_REQUIRED', 'name is required to create a category');
    end if;
    if not exists (select 1 from public.vendors v
                    where v.id = (p_patch->>'vendor_id')::uuid and v.deleted_at is null) then
      perform private.err('VENDOR_NOT_LIVE', 'no live vendor with that id');
    end if;
    insert into public.menu_categories (vendor_id, name, name_ar, description, display_order, is_available)
    values ((p_patch->>'vendor_id')::uuid, p_patch->>'name', p_patch->>'name_ar', p_patch->>'description',
            coalesce((p_patch->>'display_order')::integer, 0),
            coalesce((p_patch->>'is_available')::boolean, true))
    returning id into v_id;
  else
    -- Re-homing a category re-homes every item under it, because sync_menu_item_vendor derives each
    -- item's vendor from its category. See the header.
    if p_patch ? 'vendor_id' then
      perform private.err('IMMUTABLE_FIELD',
        'a category cannot be moved to another vendor; delete it and create it again');
    end if;
    select exists (select 1 from public.menu_categories mc where mc.id = p_id and mc.deleted_at is null)
      into v_exists;
    if not v_exists then
      perform private.err('NOT_FOUND', 'no live category with that id; restore it first');
    end if;
    update public.menu_categories mc set
      name         = coalesce(p_patch->>'name', mc.name),
      name_ar      = coalesce(p_patch->>'name_ar', mc.name_ar),
      description  = coalesce(p_patch->>'description', mc.description),
      display_order = coalesce((p_patch->>'display_order')::integer, mc.display_order),
      is_available = coalesce((p_patch->>'is_available')::boolean, mc.is_available)
     where mc.id = p_id
    returning mc.id into v_id;
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('menu_category.updated', 'menu_category', v_id,
          jsonb_build_object('actor', v_user, 'fields',
                             (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));
  return v_id;
end;
$$;
revoke execute on function public.admin_upsert_menu_category_v1(jsonb, uuid) from public, anon;
grant  execute on function public.admin_upsert_menu_category_v1(jsonb, uuid) to authenticated;

create or replace function public.admin_delete_menu_category_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_soft timestamptz;
  v_live_items integer;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'menu categories are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'category id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;
  select mc.deleted_at into v_soft from public.menu_categories mc where mc.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such category'); end if;
  if v_soft is not null then perform private.err('ALREADY_DELETED', 'this category is already soft-deleted'); end if;

  -- menu_items_read does not check the parent category, so a live item under a deleted category
  -- stays directly readable. Refusing here is what keeps that state unreachable.
  select count(*) into v_live_items
    from public.menu_items mi where mi.category_id = p_id and mi.deleted_at is null;
  if v_live_items > 0 then
    perform private.err('CATEGORY_NOT_EMPTY',
      'archive the ' || v_live_items || ' live item(s) in this category first');
  end if;

  -- deleted_at alone is sufficient here: menu_categories_read filters it.
  update public.menu_categories mc set deleted_at = now() where mc.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('menu_category.deleted', 'menu_category', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_delete_menu_category_v1(uuid, text) from public, anon;
grant  execute on function public.admin_delete_menu_category_v1(uuid, text) to authenticated;

create or replace function public.admin_restore_menu_category_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'menu categories are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'category id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;
  select mc.deleted_at into v_soft from public.menu_categories mc where mc.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such category'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this category is not soft-deleted'); end if;

  -- is_available deliberately NOT set to true. Restore un-archives; it does not publish.
  update public.menu_categories mc set deleted_at = null where mc.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('menu_category.restored', 'menu_category', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_restore_menu_category_v1(uuid, text) from public, anon;
grant  execute on function public.admin_restore_menu_category_v1(uuid, text) to authenticated;

-- =============================================================================================
-- 2. menu_items
-- =============================================================================================
create or replace function public.admin_upsert_menu_item_v1(p_patch jsonb, p_id uuid default null)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_id uuid;
  v_allowed constant text[] := array[
    'category_id','name','name_ar','description','description_ar','pricing_mode','base_price',
    'is_available','stock_count','preparation_time_minutes','image_path','display_order',
    'nutritional_info','allergens','ingredients','tags','calories',
    'is_spicy','is_vegetarian','is_featured','is_new'
  ];
  v_unknown text;
  v_soft timestamptz;
  v_mode_cur text; v_price_cur integer;
  v_mode text; v_price integer;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'menu items are admin only'); end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;

  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_patch) as k
   where not (k = any (v_allowed));
  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not a menu_items column: ' || v_unknown);
  end if;

  -- tags is text[]; a jsonb scalar or an array of non-strings would fail the cast with a raw
  -- driver error instead of a code, so it is checked here.
  if p_patch ? 'tags' then
    if jsonb_typeof(p_patch->'tags') <> 'array'
       or exists (select 1 from jsonb_array_elements(p_patch->'tags') e where jsonb_typeof(e) <> 'string')
    then
      perform private.err('PATCH_INVALID', 'tags must be a JSON array of strings');
    end if;
  end if;

  if p_id is null then
    if (p_patch->>'category_id') is null then
      perform private.err('KEY_REQUIRED', 'category_id is required to create an item');
    end if;
    if (p_patch->>'name') is null then
      perform private.err('KEY_REQUIRED', 'name is required to create an item');
    end if;
    if not exists (select 1 from public.menu_categories mc
                    where mc.id = (p_patch->>'category_id')::uuid and mc.deleted_at is null) then
      perform private.err('CATEGORY_NOT_LIVE', 'no live category with that id');
    end if;

    v_mode := coalesce(p_patch->>'pricing_mode', 'fixed');
    v_price := (p_patch->>'base_price')::integer;

    -- A row created in this transaction provably has no sizes yet, so a sized insert can only end
    -- in ITEM_SIZED_BUT_NO_SIZES at commit. Saying so now is the same refusal, one error earlier.
    if v_mode = 'sized' then
      perform private.err('ITEM_SIZED_BUT_NO_SIZES',
        'create the item as fixed, add its sizes, then switch pricing_mode to sized');
    end if;
    if v_mode = 'fixed' and v_price is null then
      perform private.err('BASE_PRICE_REQUIRED',
        'a fixed-price item needs base_price; use pricing_mode sized to price by size');
    end if;

    insert into public.menu_items (
      category_id, name, name_ar, description, description_ar, pricing_mode, base_price,
      is_available, stock_count, preparation_time_minutes, image_path, display_order,
      nutritional_info, allergens, ingredients, tags, calories,
      is_spicy, is_vegetarian, is_featured, is_new)
    values ((p_patch->>'category_id')::uuid, p_patch->>'name', p_patch->>'name_ar',
            p_patch->>'description', p_patch->>'description_ar', v_mode, v_price,
            coalesce((p_patch->>'is_available')::boolean, true),
            (p_patch->>'stock_count')::integer,
            (p_patch->>'preparation_time_minutes')::integer, p_patch->>'image_path',
            coalesce((p_patch->>'display_order')::integer, 0),
            nullif(p_patch->'nutritional_info', 'null'::jsonb),
            nullif(p_patch->'allergens', 'null'::jsonb),
            nullif(p_patch->'ingredients', 'null'::jsonb),
            -- tags is NOT NULL. An explicit NULL overrides the column default, so absent means
            -- empty rather than NULL; otherwise a patch without tags fails on the constraint.
            coalesce((p_patch->'tags')::text[], '{}'::text[]),
            (p_patch->>'calories')::integer,
            coalesce((p_patch->>'is_spicy')::boolean, false),
            coalesce((p_patch->>'is_vegetarian')::boolean, false),
            coalesce((p_patch->>'is_featured')::boolean, false),
            coalesce((p_patch->>'is_new')::boolean, false))
    returning id into v_id;
    -- vendor_id is not in the column list on purpose. sync_menu_item_vendor derives it.
  else
    select mi.deleted_at, mi.pricing_mode, mi.base_price
      into v_soft, v_mode_cur, v_price_cur
      from public.menu_items mi where mi.id = p_id;
    if not found then perform private.err('NOT_FOUND', 'no such item'); end if;
    if v_soft is not null then
      perform private.err('NOT_FOUND', 'this item is soft-deleted; restore it first');
    end if;

    if p_patch ? 'category_id'
       and not exists (select 1 from public.menu_categories mc
                        where mc.id = (p_patch->>'category_id')::uuid and mc.deleted_at is null) then
      perform private.err('CATEGORY_NOT_LIVE', 'no live category with that id');
    end if;

    v_mode := coalesce(p_patch->>'pricing_mode', v_mode_cur);
    v_price := coalesce((p_patch->>'base_price')::integer, v_price_cur);

    -- No pre-check that a sized item has sizes. The caller may be adding them in this same
    -- transaction, and assert_item_has_sizes runs at commit precisely so that ordering is legal.
    if v_mode = 'fixed' and v_price is null then
      perform private.err('BASE_PRICE_REQUIRED',
        'a fixed-price item needs base_price; use pricing_mode sized to price by size');
    end if;

    update public.menu_items mi set
      category_id   = coalesce((p_patch->>'category_id')::uuid, mi.category_id),
      name          = coalesce(p_patch->>'name', mi.name),
      name_ar       = coalesce(p_patch->>'name_ar', mi.name_ar),
      description   = coalesce(p_patch->>'description', mi.description),
      description_ar = coalesce(p_patch->>'description_ar', mi.description_ar),
      pricing_mode  = v_mode,
      base_price    = v_price,
      is_available  = coalesce((p_patch->>'is_available')::boolean, mi.is_available),
      stock_count   = coalesce((p_patch->>'stock_count')::integer, mi.stock_count),
      preparation_time_minutes = coalesce((p_patch->>'preparation_time_minutes')::integer, mi.preparation_time_minutes),
      image_path    = coalesce(p_patch->>'image_path', mi.image_path),
      display_order = coalesce((p_patch->>'display_order')::integer, mi.display_order),
      -- JSON null means clear for these three; an absent key means leave alone. nullif() is what
      -- distinguishes the two, because jsonb 'null' is not SQL NULL.
      nutritional_info = case when p_patch ? 'nutritional_info'
                              then nullif(p_patch->'nutritional_info', 'null'::jsonb)
                              else mi.nutritional_info end,
      allergens       = case when p_patch ? 'allergens'
                              then nullif(p_patch->'allergens', 'null'::jsonb)
                              else mi.allergens end,
      ingredients     = case when p_patch ? 'ingredients'
                              then nullif(p_patch->'ingredients', 'null'::jsonb)
                              else mi.ingredients end,
      tags        = coalesce((p_patch->'tags')::text[], mi.tags),
      calories    = coalesce((p_patch->>'calories')::integer, mi.calories),
      is_spicy    = coalesce((p_patch->>'is_spicy')::boolean, mi.is_spicy),
      is_vegetarian = coalesce((p_patch->>'is_vegetarian')::boolean, mi.is_vegetarian),
      is_featured = coalesce((p_patch->>'is_featured')::boolean, mi.is_featured),
      is_new      = coalesce((p_patch->>'is_new')::boolean, mi.is_new)
     where mi.id = p_id
    returning mi.id into v_id;
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('menu_item.updated', 'menu_item', v_id,
          jsonb_build_object('actor', v_user, 'fields',
                             (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));
  return v_id;
end;
$$;
revoke execute on function public.admin_upsert_menu_item_v1(jsonb, uuid) from public, anon;
grant  execute on function public.admin_upsert_menu_item_v1(jsonb, uuid) to authenticated;

create or replace function public.admin_delete_menu_item_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_soft timestamptz;
  v_live_children integer;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'menu items are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'item id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;
  select mi.deleted_at into v_soft from public.menu_items mi where mi.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such item'); end if;
  if v_soft is not null then perform private.err('ALREADY_DELETED', 'this item is already soft-deleted'); end if;

  -- Neither menu_item_sizes_read nor item_options_read checks the parent item, so a live child of a
  -- deleted item stays directly readable. Same reasoning as CATEGORY_NOT_EMPTY, one level down.
  select (select count(*) from public.menu_item_sizes s
           where s.item_id = p_id and s.deleted_at is null)
       + (select count(*) from public.item_options o
           where o.item_id = p_id and o.deleted_at is null)
    into v_live_children;
  if v_live_children > 0 then
    perform private.err('ITEM_NOT_EMPTY',
      'archive the ' || v_live_children || ' live size(s) and option(s) of this item first');
  end if;

  update public.menu_items mi set deleted_at = now() where mi.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('menu_item.deleted', 'menu_item', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_delete_menu_item_v1(uuid, text) from public, anon;
grant  execute on function public.admin_delete_menu_item_v1(uuid, text) to authenticated;

create or replace function public.admin_restore_menu_item_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'menu items are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'item id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;
  select mi.deleted_at into v_soft from public.menu_items mi where mi.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such item'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this item is not soft-deleted'); end if;

  update public.menu_items mi set deleted_at = null where mi.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('menu_item.restored', 'menu_item', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_restore_menu_item_v1(uuid, text) from public, anon;
grant  execute on function public.admin_restore_menu_item_v1(uuid, text) to authenticated;

-- =============================================================================================
-- 3. menu_item_sizes
-- =============================================================================================
create or replace function public.admin_upsert_menu_item_size_v1(p_patch jsonb, p_id uuid default null)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_id uuid;
  v_allowed constant text[] := array[
    'item_id','name','name_ar','price','is_default','is_available','calories','display_order'
  ];
  v_unknown text;
  v_exists boolean;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'menu item sizes are admin only'); end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;

  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_patch) as k
   where not (k = any (v_allowed));
  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not a menu_item_sizes column: ' || v_unknown);
  end if;

  if p_id is null then
    if (p_patch->>'item_id') is null then
      perform private.err('KEY_REQUIRED', 'item_id is required to create a size');
    end if;
    if (p_patch->>'name') is null then
      perform private.err('KEY_REQUIRED', 'name is required to create a size');
    end if;
    if not exists (select 1 from public.menu_items mi
                    where mi.id = (p_patch->>'item_id')::uuid and mi.deleted_at is null) then
      perform private.err('ITEM_NOT_LIVE', 'no live item with that id');
    end if;
    insert into public.menu_item_sizes (item_id, name, name_ar, price, is_default, is_available,
                                        calories, display_order)
    values ((p_patch->>'item_id')::uuid, p_patch->>'name', p_patch->>'name_ar',
            coalesce((p_patch->>'price')::integer, 0),
            coalesce((p_patch->>'is_default')::boolean, false),
            coalesce((p_patch->>'is_available')::boolean, true),
            (p_patch->>'calories')::integer,
            coalesce((p_patch->>'display_order')::integer, 0))
    returning id into v_id;
  else
    if p_patch ? 'item_id'
       and not exists (select 1 from public.menu_items mi
                        where mi.id = (p_patch->>'item_id')::uuid and mi.deleted_at is null) then
      perform private.err('ITEM_NOT_LIVE', 'no live item with that id');
    end if;
    select exists (select 1 from public.menu_item_sizes s where s.id = p_id and s.deleted_at is null)
      into v_exists;
    if not v_exists then
      perform private.err('NOT_FOUND', 'no live size with that id; restore it first');
    end if;
    update public.menu_item_sizes s set
      item_id       = coalesce((p_patch->>'item_id')::uuid, s.item_id),
      name          = coalesce(p_patch->>'name', s.name),
      name_ar       = coalesce(p_patch->>'name_ar', s.name_ar),
      price         = coalesce((p_patch->>'price')::integer, s.price),
      is_default    = coalesce((p_patch->>'is_default')::boolean, s.is_default),
      is_available  = coalesce((p_patch->>'is_available')::boolean, s.is_available),
      calories      = coalesce((p_patch->>'calories')::integer, s.calories),
      display_order = coalesce((p_patch->>'display_order')::integer, s.display_order)
     where s.id = p_id
    returning s.id into v_id;
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('menu_item_size.updated', 'menu_item_size', v_id,
          jsonb_build_object('actor', v_user, 'fields',
                             (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));
  return v_id;
end;
$$;
revoke execute on function public.admin_upsert_menu_item_size_v1(jsonb, uuid) from public, anon;
grant  execute on function public.admin_upsert_menu_item_size_v1(jsonb, uuid) to authenticated;

create or replace function public.admin_delete_menu_item_size_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_soft timestamptz;
  v_item uuid;
  v_mode text;
  v_live_siblings integer;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'menu item sizes are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'size id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;
  select s.deleted_at, s.item_id into v_soft, v_item
    from public.menu_item_sizes s where s.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such size'); end if;
  if v_soft is not null then perform private.err('ALREADY_DELETED', 'this size is already soft-deleted'); end if;

  -- assert_item_still_sized counts menu_item_sizes rows WITHOUT filtering deleted_at, so a soft
  -- delete does not register as a removal and the schema's own guard lets a sized item end up
  -- with no purchasable size. This closes that, because this is the only function that can cause it.
  select mi.pricing_mode into v_mode from public.menu_items mi where mi.id = v_item;
  if v_mode = 'sized' then
    select count(*) into v_live_siblings
      from public.menu_item_sizes s where s.item_id = v_item and s.deleted_at is null;
    if v_live_siblings <= 1 then
      perform private.err('LAST_SIZE_PROTECTED',
        'this is the last live size of a sized item; switch the item to fixed pricing or add another size');
    end if;
  end if;

  -- is_available as well as deleted_at, because menu_item_sizes_read does not filter deleted_at.
  update public.menu_item_sizes s set deleted_at = now(), is_available = false where s.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('menu_item_size.deleted', 'menu_item_size', p_id,
          jsonb_build_object('actor', v_user, 'item_id', v_item, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_delete_menu_item_size_v1(uuid, text) from public, anon;
grant  execute on function public.admin_delete_menu_item_size_v1(uuid, text) to authenticated;

create or replace function public.admin_restore_menu_item_size_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'menu item sizes are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'size id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;
  select s.deleted_at into v_soft from public.menu_item_sizes s where s.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such size'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this size is not soft-deleted'); end if;

  -- is_available deliberately NOT restored to true. Un-archive is not publish.
  update public.menu_item_sizes s set deleted_at = null where s.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('menu_item_size.restored', 'menu_item_size', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_restore_menu_item_size_v1(uuid, text) from public, anon;
grant  execute on function public.admin_restore_menu_item_size_v1(uuid, text) to authenticated;

-- =============================================================================================
-- 4. item_options
-- =============================================================================================
create or replace function public.admin_upsert_item_option_v1(p_patch jsonb, p_id uuid default null)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_id uuid;
  v_allowed constant text[] := array[
    'item_id','name','name_ar','is_required','min_selections','max_selections',
    'is_available','display_order'
  ];
  v_unknown text;
  v_soft timestamptz;
  v_required_cur boolean; v_max_cur integer; v_min_cur integer;
  v_required boolean; v_max integer; v_min integer;
  v_live_choices integer;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'item options are admin only'); end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;

  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_patch) as k
   where not (k = any (v_allowed));
  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not an item_options column: ' || v_unknown);
  end if;

  if p_id is null then
    if (p_patch->>'item_id') is null then
      perform private.err('KEY_REQUIRED', 'item_id is required to create an option');
    end if;
    if (p_patch->>'name') is null then
      perform private.err('KEY_REQUIRED', 'name is required to create an option');
    end if;
    if not exists (select 1 from public.menu_items mi
                    where mi.id = (p_patch->>'item_id')::uuid and mi.deleted_at is null) then
      perform private.err('ITEM_NOT_LIVE', 'no live item with that id');
    end if;
    v_required := coalesce((p_patch->>'is_required')::boolean, false);
    v_min := coalesce((p_patch->>'min_selections')::integer, 0);
    v_max := coalesce((p_patch->>'max_selections')::integer, 1);
    -- option_selections_sane permits is_required with max_selections = 0, which is a group the
    -- customer must pick from and may pick nothing from.
    if v_required and v_max = 0 then
      perform private.err('OPTION_REQUIRED_UNSATISFIABLE',
        'an option with is_required true must allow at least one selection');
    end if;
    insert into public.item_options (item_id, name, name_ar, is_required, min_selections,
                                    max_selections, is_available, display_order)
    values ((p_patch->>'item_id')::uuid, p_patch->>'name', p_patch->>'name_ar', v_required, v_min, v_max,
            coalesce((p_patch->>'is_available')::boolean, true),
            coalesce((p_patch->>'display_order')::integer, 0))
    returning id into v_id;
  else
    select o.deleted_at, o.is_required, o.min_selections, o.max_selections
      into v_soft, v_required_cur, v_min_cur, v_max_cur
      from public.item_options o where o.id = p_id;
    if not found then perform private.err('NOT_FOUND', 'no such option'); end if;
    if v_soft is not null then
      perform private.err('NOT_FOUND', 'this option is soft-deleted; restore it first');
    end if;

    if p_patch ? 'item_id'
       and not exists (select 1 from public.menu_items mi
                        where mi.id = (p_patch->>'item_id')::uuid and mi.deleted_at is null) then
      perform private.err('ITEM_NOT_LIVE', 'no live item with that id');
    end if;

    v_required := coalesce((p_patch->>'is_required')::boolean, v_required_cur);
    v_max := coalesce((p_patch->>'max_selections')::integer, v_max_cur);
    v_min := coalesce((p_patch->>'min_selections')::integer, v_min_cur);

    if v_required and v_max = 0 then
      perform private.err('OPTION_REQUIRED_UNSATISFIABLE',
        'an option with is_required true must allow at least one selection');
    end if;

    -- Raising max_selections above the number of live choices is the same contradiction reached from
    -- the other side, so an edit that touches the selection bounds is checked against reality.
    -- Skipped when the patch does not touch them, so a pure rename of a pre-existing oddity is not
    -- blocked by a problem this function did not create.
    if p_patch ? 'min_selections' or p_patch ? 'max_selections' or p_patch ? 'is_required' then
      select count(*) into v_live_choices
        from public.option_choices oc
       where oc.option_id = p_id and oc.deleted_at is null;
      if v_live_choices < v_max then
        perform private.err('OPTION_UNSATISFIABLE',
          'max_selections is ' || v_max || ' but only ' || v_live_choices
          || ' live choice(s) exist; add choices or lower max_selections');
      end if;
    end if;

    update public.item_options o set
      item_id        = coalesce((p_patch->>'item_id')::uuid, o.item_id),
      name           = coalesce(p_patch->>'name', o.name),
      name_ar        = coalesce(p_patch->>'name_ar', o.name_ar),
      is_required    = v_required,
      min_selections = v_min,
      max_selections = v_max,
      is_available   = coalesce((p_patch->>'is_available')::boolean, o.is_available),
      display_order  = coalesce((p_patch->>'display_order')::integer, o.display_order)
     where o.id = p_id
    returning o.id into v_id;
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('item_option.updated', 'item_option', v_id,
          jsonb_build_object('actor', v_user, 'fields',
                             (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));
  return v_id;
end;
$$;
revoke execute on function public.admin_upsert_item_option_v1(jsonb, uuid) from public, anon;
grant  execute on function public.admin_upsert_item_option_v1(jsonb, uuid) to authenticated;

create or replace function public.admin_delete_item_option_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_soft timestamptz;
  v_live_choices integer;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'item options are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'option id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;
  select o.deleted_at into v_soft from public.item_options o where o.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such option'); end if;
  if v_soft is not null then perform private.err('ALREADY_DELETED', 'this option is already soft-deleted'); end if;

  -- option_choices_read does not check the parent option, so live choices under a deleted option
  -- would stay readable. Archive them first.
  select count(*) into v_live_choices
    from public.option_choices oc where oc.option_id = p_id and oc.deleted_at is null;
  if v_live_choices > 0 then
    perform private.err('OPTION_NOT_EMPTY',
      'archive the ' || v_live_choices || ' live choice(s) of this option first');
  end if;

  update public.item_options o set deleted_at = now(), is_available = false where o.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('item_option.deleted', 'item_option', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_delete_item_option_v1(uuid, text) from public, anon;
grant  execute on function public.admin_delete_item_option_v1(uuid, text) to authenticated;

create or replace function public.admin_restore_item_option_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'item options are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'option id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;
  select o.deleted_at into v_soft from public.item_options o where o.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such option'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this option is not soft-deleted'); end if;

  update public.item_options o set deleted_at = null where o.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('item_option.restored', 'item_option', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_restore_item_option_v1(uuid, text) from public, anon;
grant  execute on function public.admin_restore_item_option_v1(uuid, text) to authenticated;

-- =============================================================================================
-- 5. option_choices
-- =============================================================================================
create or replace function public.admin_upsert_option_choice_v1(p_patch jsonb, p_id uuid default null)
returns uuid
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_id uuid;
  v_allowed constant text[] := array[
    'option_id','name','name_ar','price_modifier','is_default','is_available',
    'stock_count','calories','display_order'
  ];
  v_unknown text;
  v_exists boolean;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'option choices are admin only'); end if;
  if p_patch is null or p_patch = '{}'::jsonb then
    perform private.err('PATCH_EMPTY', 'the patch carries no fields');
  end if;

  select string_agg(k, ', ' order by k) into v_unknown
    from jsonb_object_keys(p_patch) as k
   where not (k = any (v_allowed));
  if v_unknown is not null then
    perform private.err('UNKNOWN_KEY', 'not an option_choices column: ' || v_unknown);
  end if;

  if p_id is null then
    if (p_patch->>'option_id') is null then
      perform private.err('KEY_REQUIRED', 'option_id is required to create a choice');
    end if;
    if (p_patch->>'name') is null then
      perform private.err('KEY_REQUIRED', 'name is required to create a choice');
    end if;
    if not exists (select 1 from public.item_options o
                    where o.id = (p_patch->>'option_id')::uuid and o.deleted_at is null) then
      perform private.err('OPTION_NOT_LIVE', 'no live option with that id');
    end if;
    insert into public.option_choices (option_id, name, name_ar, price_modifier, is_default,
                                       is_available, stock_count, calories, display_order)
    values ((p_patch->>'option_id')::uuid, p_patch->>'name', p_patch->>'name_ar',
            coalesce((p_patch->>'price_modifier')::integer, 0),
            coalesce((p_patch->>'is_default')::boolean, false),
            coalesce((p_patch->>'is_available')::boolean, true),
            (p_patch->>'stock_count')::integer,
            (p_patch->>'calories')::integer,
            coalesce((p_patch->>'display_order')::integer, 0))
    returning id into v_id;
  else
    if p_patch ? 'option_id'
       and not exists (select 1 from public.item_options o
                        where o.id = (p_patch->>'option_id')::uuid and o.deleted_at is null) then
      perform private.err('OPTION_NOT_LIVE', 'no live option with that id');
    end if;
    select exists (select 1 from public.option_choices oc where oc.id = p_id and oc.deleted_at is null)
      into v_exists;
    if not v_exists then
      perform private.err('NOT_FOUND', 'no live choice with that id; restore it first');
    end if;
    update public.option_choices oc set
      option_id      = coalesce((p_patch->>'option_id')::uuid, oc.option_id),
      name           = coalesce(p_patch->>'name', oc.name),
      name_ar        = coalesce(p_patch->>'name_ar', oc.name_ar),
      price_modifier = coalesce((p_patch->>'price_modifier')::integer, oc.price_modifier),
      is_default     = coalesce((p_patch->>'is_default')::boolean, oc.is_default),
      is_available   = coalesce((p_patch->>'is_available')::boolean, oc.is_available),
      stock_count    = coalesce((p_patch->>'stock_count')::integer, oc.stock_count),
      calories       = coalesce((p_patch->>'calories')::integer, oc.calories),
      display_order  = coalesce((p_patch->>'display_order')::integer, oc.display_order)
     where oc.id = p_id
    returning oc.id into v_id;
  end if;

  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('option_choice.updated', 'option_choice', v_id,
          jsonb_build_object('actor', v_user, 'fields',
                             (select jsonb_agg(k order by k) from jsonb_object_keys(p_patch) k)));
  return v_id;
end;
$$;
revoke execute on function public.admin_upsert_option_choice_v1(jsonb, uuid) from public, anon;
grant  execute on function public.admin_upsert_option_choice_v1(jsonb, uuid) to authenticated;

create or replace function public.admin_delete_option_choice_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_soft timestamptz;
  v_option uuid;
  v_max integer;
  v_live_siblings integer;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'option choices are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'choice id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every soft delete');
  end if;
  select oc.deleted_at, oc.option_id into v_soft, v_option
    from public.option_choices oc where oc.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such choice'); end if;
  if v_soft is not null then perform private.err('ALREADY_DELETED', 'this choice is already soft-deleted'); end if;

  -- The same contradiction OPTION_UNSATISFIABLE guards on edit, reached by deletion instead: an
  -- option that promises max_selections it can no longer deliver.
  select o.max_selections into v_max from public.item_options o where o.id = v_option;
  select count(*) into v_live_siblings
    from public.option_choices oc where oc.option_id = v_option and oc.deleted_at is null;
  if v_live_siblings - 1 < v_max then
    perform private.err('OPTION_UNSATISFIABLE',
      'deleting this choice would leave ' || (v_live_siblings - 1)
      || ' live choice(s) for an option that allows ' || v_max
      || '; lower max_selections first');
  end if;

  -- is_available as well as deleted_at, because option_choices_read does not filter deleted_at.
  update public.option_choices oc set deleted_at = now(), is_available = false where oc.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('option_choice.deleted', 'option_choice', p_id,
          jsonb_build_object('actor', v_user, 'option_id', v_option, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_delete_option_choice_v1(uuid, text) from public, anon;
grant  execute on function public.admin_delete_option_choice_v1(uuid, text) to authenticated;

create or replace function public.admin_restore_option_choice_v1(p_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $$
declare v_user uuid := auth.uid(); v_soft timestamptz;
begin
  if v_user is null then perform private.err('AUTH_REQUIRED', 'sign in first'); end if;
  if not private.is_admin() then perform private.err('NOT_AUTHORIZED', 'option choices are admin only'); end if;
  if p_id is null then perform private.err('KEY_REQUIRED', 'choice id is required'); end if;
  if p_reason is null or btrim(p_reason) = '' then
    perform private.err('REASON_REQUIRED', 'a reason is mandatory for every restore');
  end if;
  select oc.deleted_at into v_soft from public.option_choices oc where oc.id = p_id;
  if not found then perform private.err('NOT_FOUND', 'no such choice'); end if;
  if v_soft is null then perform private.err('NOT_DELETED', 'this choice is not soft-deleted'); end if;

  update public.option_choices oc set deleted_at = null where oc.id = p_id;
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('option_choice.restored', 'option_choice', p_id,
          jsonb_build_object('actor', v_user, 'reason', btrim(p_reason)));
end;
$$;
revoke execute on function public.admin_restore_option_choice_v1(uuid, text) from public, anon;
grant  execute on function public.admin_restore_option_choice_v1(uuid, text) to authenticated;

-- =============================================================================================
-- Assertions
-- =============================================================================================
do $$
declare
  v_expected constant text[] := array[
    'admin_upsert_menu_category_v1','admin_upsert_menu_item_v1','admin_upsert_menu_item_size_v1',
    'admin_upsert_item_option_v1','admin_upsert_option_choice_v1',
    'admin_delete_menu_category_v1','admin_delete_menu_item_v1','admin_delete_menu_item_size_v1',
    'admin_delete_item_option_v1','admin_delete_option_choice_v1',
    'admin_restore_menu_category_v1','admin_restore_menu_item_v1','admin_restore_menu_item_size_v1',
    'admin_restore_item_option_v1','admin_restore_option_choice_v1'
  ];
  v_missing text; v_not_definer text; v_unpinned text; v_anon_exec integer;
  v_bad_param text; v_no_revoke text; v_no_delete text; v_forbidden text; v_no_vendor text;
  v_opt_flag text; v_updated_at_offenders text;
begin
  -- 1. All fifteen exist, by name rather than by count, so a typo fails here instead of leaving
  --    the console with a missing function and a correct-looking total.
  select string_agg(e, ', ' order by e) into v_missing
    from unnest(v_expected) as e
   where not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'public' and p.proname = e);
  if v_missing is not null then
    raise exception 'FAIL CLOSED: 027 did not create: %', v_missing;
  end if;

  -- 2. All fifteen are SECURITY DEFINER. Each writes a table RLS restricts and re-derives its own
  --    admin decision rather than inheriting a policy.
  select string_agg(p.proname, ', ' order by p.proname) into v_not_definer
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (v_expected) and not p.prosecdef;
  if v_not_definer is not null then
    raise exception 'FAIL CLOSED: not SECURITY DEFINER: %', v_not_definer;
  end if;

  -- 3. All fifteen pin search_path. Suite check 10 covers this too; naming the migration here means
  --    a failure points at the file that caused it.
  select string_agg(p.proname, ', ' order by p.proname) into v_unpinned
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (v_expected)
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) cfg
                      where cfg like 'search\_path=%');
  if v_unpinned is not null then
    raise exception 'FAIL CLOSED: unpinned search_path on: %', v_unpinned;
  end if;

  -- 4. No admin function takes a table or operation name. This is what keeps the rejected generic
  --    admin_write_v1(p_table, p_op, p_payload) from creeping back in.
  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    into v_bad_param
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (v_expected)
     and exists (select 1 from unnest(p.proargnames) arg
                  where lower(arg) in ('p_table','table_name','p_op','p_operation','operation'));
  if v_bad_param is not null then
    raise exception
      'FAIL CLOSED: an admin function takes a table or operation name, so a client value would select the write: %',
      v_bad_param;
  end if;

  -- 5. anon holds no EXECUTE on any of the fifteen. A signed-out visitor must not be able to probe
  --    whether a dish exists, let alone write one. This is the assertion class that caught a missing
  --    revoke in 025, and it is here for the same reason.
  select count(*) into v_anon_exec
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (v_expected)
     and has_function_privilege('anon', p.oid, 'EXECUTE');
  if v_anon_exec <> 0 then
    raise exception 'FAIL CLOSED: anon can EXECUTE % of the 15 admin functions', v_anon_exec;
  end if;

  -- 6. authenticated CAN execute all fifteen, or the admin console cannot call them.
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = any (v_expected)
                 and not has_function_privilege('authenticated', p.oid, 'EXECUTE'))
  then
    raise exception 'FAIL CLOSED: authenticated cannot execute one or more of the 15 admin functions';
  end if;

  -- 7. PUBLIC holds no EXECUTE either. `create or replace function` re-grants EXECUTE to PUBLIC by
  --    default, so a revoke naming only anon would leave PUBLIC holding it and anon reachable through
  --    it. Checked separately from 5 on purpose: 5 passes when anon was revoked but PUBLIC was not.
  select string_agg(p.proname, ', ' order by p.proname) into v_no_revoke
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (v_expected)
     and has_function_privilege('public', p.oid, 'EXECUTE');
  if v_no_revoke is not null then
    raise exception 'FAIL CLOSED: PUBLIC can EXECUTE, so anon reaches these through it: %', v_no_revoke;
  end if;

  -- 8. NO admin function issues a DELETE. Soft delete is the only admin delete.
  --
  --    The pattern is `(^|[^a-z_])delete\s+from`. `delete` preceded by a non-word character or the
  --    start, then whitespace, then `from`. The leading guard is what keeps it from matching the
  --    `deleted_at` column this file is full of: in `deleted_at` the "delete" is followed by `d`,
  --    not whitespace.
  --
  --    Three earlier attempts at this assertion, across 026, matched nothing and were each shipped
  --    by a green run before being caught. `\melete\b` matches the literal word "elete";
  --    `\mdelete\s+from\b` looks right and still matches nothing on this Postgres 17 build. That is
  --    why assertion 9 exists: a regex that cannot fail is not a check.
  select string_agg(p.proname, ', ' order by p.proname) into v_no_delete
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (v_expected)
     and pg_get_functiondef(p.oid) ~* '(^|[^a-z_])delete\s+from';
  if v_no_delete is not null then
    raise exception
      'FAIL CLOSED: these admin functions contain a DELETE statement, and soft delete is the only admin delete: %',
      v_no_delete;
  end if;

  -- 9. The negative test for assertion 8, in both directions. Without it, assertion 8 is an
  --    unfalsifiable claim about a regex, which is exactly what three earlier versions of it were.
  declare v_probe text;
  begin
    v_probe := 'begin delete from public.menu_items; end;';
    if v_probe !~* '(^|[^a-z_])delete\s+from' then
      raise exception
        'FAIL CLOSED: the no-DELETE check cannot detect a DELETE, so assertion 8 proves nothing';
    end if;
    if 'update public.menu_items mi set deleted_at = now()' ~* '(^|[^a-z_])delete\s+from' then
      raise exception
        'FAIL CLOSED: the no-DELETE check false-positives on deleted_at, so it would block correct code';
    end if;
  end;

  -- 10. No body names a GENERATED column or a system-owned one. `name_normalized`,
  --     `name_ar_normalized` and `ingredients_normalized` are GENERATED from 015 and unwritable by
  --     anyone; `menu_version` is bumped by the 005b statement triggers, and `rating_avg` /
  --     `rating_count` are recomputed from reviews. A body that merely MENTIONS one of these in the
  --     insert or update list would silently do nothing, or worse, desynchronise the R2 snapshot
  --     pointer. pg_get_functiondef does not return comments, so this cannot be tripped by prose.
  select string_agg(p.proname, ', ' order by p.proname) into v_forbidden
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = any (v_expected)
     and pg_get_functiondef(p.oid) ~* '(name_normalized|name_ar_normalized|ingredients_normalized|menu_version|rating_avg|rating_count)';
  if v_forbidden is not null then
    raise exception
      'FAIL CLOSED: these admin function bodies reference a generated or system-owned column: %',
      v_forbidden;
  end if;

  -- 11. `menu_items.vendor_id` is derived by sync_menu_item_vendor and must stay out of the item
  --     writer. This is the one derived column whose absence a caller could otherwise mistake for a
  --     missing feature, so it is asserted rather than merely left off the allowlist.
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'admin_upsert_menu_item_v1'
                 and pg_get_functiondef(p.oid) ilike '%vendor_id%')
  then
    raise exception
      'FAIL CLOSED: admin_upsert_menu_item_v1 mentions vendor_id; that column is derived from the category by sync_menu_item_vendor';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = 'sync_menu_item_vendor')
  then
    raise exception 'FAIL CLOSED: sync_menu_item_vendor is gone, so menu_items.vendor_id is now writable';
  end if;

  -- 12. The amendment that made soft delete work on item_options is present, and its read policy
  --     actually consults both the new flag and deleted_at. A migration that added the column but
  --     failed to amend the policy would pass every other assertion here and still be a no-op.
  select case when exists (select 1 from pg_attribute a
                             join pg_class c on c.oid = a.attrelid
                             join pg_namespace n on n.oid = c.relnamespace
                            where n.nspname = 'public' and c.relname = 'item_options'
                              and a.attname = 'is_available' and not a.attisdropped)
              then null else 'item_options.is_available is missing' end
    into v_opt_flag;
  if v_opt_flag is not null then
    raise exception 'FAIL CLOSED: %', v_opt_flag;
  end if;
  if not exists (select 1 from pg_policies
                   where schemaname = 'public' and tablename = 'item_options'
                     and policyname = 'item_options_read'
                     and (qual ilike '%is_available%' and qual ilike '%deleted_at%'))
  then
    raise exception
      'FAIL CLOSED: item_options_read does not filter on is_available and deleted_at, so a soft delete stays visible to customers';
  end if;

  -- 13. The suite's own trigger check, called rather than re-implemented, so this migration and the
  --     suite cannot disagree about what "has the trigger" means. 027 adds no updated_at column, but
  --     the amendment above touched an applied table and this is the cheap way to stay honest.
  --
  --     nullif() is load-bearing and was found the hard way: the function returns '' when there are
  --     no offenders, NOT null, so a bare `is not null` test fails on a clean database. The first
  --     apply of this migration raised FAIL CLOSED on a passing check for exactly that reason.
  v_updated_at_offenders := nullif(tests.updated_at_trigger_offenders(), '');
  if v_updated_at_offenders is not null then
    raise exception 'FAIL CLOSED: tables own updated_at without a trigger: %', v_updated_at_offenders;
  end if;
end $$;
