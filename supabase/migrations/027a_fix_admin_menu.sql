-- 027a: two defects in `027_admin_menu.sql`, both of which shipped green.
--
-- `027` is applied (20261005164418). It passed its own thirteen assertions and it passes
-- `tests.run_all()` (11/11). Both of those facts were true while the catalog was unusable:
-- `admin_upsert_menu_item_v1` had never successfully run once, and two of the five catalog
-- tables could not be read by any signed-in client. Found by executing the surface by hand,
-- in a rolled-back transaction, as admin and as customer.
--
-- Why the assertions missed both, because this is the part worth keeping:
--
--   * All thirteen of `027`'s assertions read `pg_proc` and `pg_policies` AS TEXT. None of them
--     executed a function body, and none executed a SELECT. A body that is syntactically perfect
--     and semantically dead passes every one of them. `tests.run_all()` has the same blind spot:
--     it counts policies, it does not run them.
--   * Assertion 12 checked `item_options_read`'s qual for `%is_available%` and `%deleted_at%`.
--     Both substrings are present in a policy that raises on every use.
--
-- So the fix here is not only the two defects. Assertions 3 and 4 below EXECUTE the thing they
-- check, which is the check `027` should have had and did not.
--
-- =============================================================================================
-- DEFECT 1 - `admin_upsert_menu_item_v1` could never create or update a menu item
-- =============================================================================================
-- `027:401` (INSERT) and `027:458` (UPDATE) both read the patch's `tags` with
--
--     coalesce((p_patch->'tags')::text[], ...)
--
-- PostgreSQL has no `jsonb -> text[]` cast. There is no `pg_cast` entry and no built-in
-- assignment cast; the only route to a text[] from jsonb is `jsonb_array_elements_text`.
-- The cast is resolved when the statement runs, not when the key is looked up, so the failure is
-- unconditional - it does not matter that `p_patch` has no `tags` key, because
-- `p_patch->'tags'` is a NULL *jsonb* and casting NULL still needs the conversion to exist:
--
--     create, no tags key   -> ERROR: cannot cast type jsonb to text[]
--     create, tags = []     -> ERROR: cannot cast type jsonb to text[]
--     update, {"name":...} -> ERROR: cannot cast type jsonb to text[]
--
-- Every create and every update failed. `admin_upsert_menu_category_v1` was the only way to put
-- a dish's parent in the database, so "load a merchant and take an order" stopped at the first
-- dish. The other fourteen functions were unaffected, which is why the file looks healthy at a
-- glance: fourteen working functions hide one dead one.
--
-- The irony is worth recording. `027:349-357` adds a dedicated `tags` validator whose stated
-- reason is that "a jsonb scalar or an array of non-strings would fail the cast with a raw
-- driver error instead of a code, so it is checked here." The guard against a bad `tags` value
-- was written, tested in my suite, and correct. The line it was guarding could not execute at
-- all.
--
-- The UPDATE branch needs a `case ... when p_patch ? 'tags'`, not a `coalesce`.
-- `array(select jsonb_array_elements_text(NULL))` yields `{}`, not NULL, so a bare coalesce would
-- take `{}` over `mi.tags` and silently wipe the tags of every item on every unrelated edit. The
-- `case` is the same shape the three jsonb columns immediately above it already use, and the
-- difference it encodes is the one that matters: an absent key means LEAVE ALONE, a present key
-- means REPLACE, and `[]` means CLEAR.
--
-- =============================================================================================
-- DEFECT 2 - `item_options_read` referenced its own table, and took `option_choices` with it
-- =============================================================================================
-- `027:167-176` wrote the vendor-staff branch as
--
--     exists (select 1 from public.item_options io
--               join public.menu_items mi on mi.id = io.item_id
--              where io.id = item_options.id ... )
--
-- on the policy `item_options_read` **on `public.item_options`**. A policy that names its own
-- table in its own USING expression is a loop, and PostgreSQL refuses to plan it:
--
--     ERROR: 42P17: infinite recursion detected in policy for relation "item_options"
--
-- This is not a subtle degradation, it is a hard error on every statement. Measured:
--
--     role          SELECT item_options            SELECT option_choices
--     -----------   --------------------------    ------------------------
--     anon          permission denied (no grant)   permission denied (no grant)
--     admin         42P17 infinite recursion       42P17 infinite recursion
--     customer      42P17 infinite recursion       42P17 infinite recursion
--
-- `option_choices_read` is collateral: it subqueries `public.item_options`, so expanding its own
-- policy expands the broken one. Two of the five catalog tables - the item-customisation group
-- and its choices - were unreadable to every signed-in client including the admin console. The
-- three that reference `menu_items` (`menu_categories_read`, `menu_items_read`,
-- `menu_item_sizes_read`) are unaffected, which is the tell: `menu_item_sizes_read` reaches
-- `menu_items` through `menu_item_sizes.item_id` and never names its own table.
--
-- The fix is the shape `027`'s own header claimed it was already using - "mirrors
-- `menu_item_sizes_read`" - reach `menu_items` directly via the row's own `item_id`. The
-- `deleted_at` filter the fix keeps is the whole point of the amendment: `item_options` had no
-- lever at all before `027`, which is why the column and the policy were added together.
--
-- The six admin functions over these two tables kept working, and that is worth being precise
-- about, because it is the reason this shipped. They are `SECURITY DEFINER` and their owner
-- bypasses RLS, so they never expand the policy. Their correctness depended on who owns the
-- functions, which is an accident of deployment and not a property any assertion checked.

-- =============================================================================================
-- FIX 1 - the policy
-- =============================================================================================
drop policy if exists item_options_read on public.item_options;
create policy item_options_read on public.item_options
  for select to authenticated
  using (
       ( item_options.is_available and item_options.deleted_at is null )
    or exists ( select 1
                  from public.menu_items mi
                 where mi.id = item_options.item_id
                   and mi.vendor_id in ( select private.vendor_ids_for(( select auth.uid() )) ) )
    or ( select private.is_admin() )
  );

-- =============================================================================================
-- FIX 2 - the tags read, in both branches
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

  -- tags is text[]; a jsonb scalar or an array of non-strings would fail the read with a raw
  -- driver error instead of a code, so it is checked here. Unchanged from 027 and still correct.
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
            -- THE FIX. jsonb_array_elements_text is the only route from jsonb to text[]. It returns
            -- zero rows for an absent key, so array() yields '{}' and the coalesce below is the
            -- documented default rather than an accident.
            coalesce(array(select jsonb_array_elements_text(p_patch->'tags')), '{}'::text[]),
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
      -- THE FIX, and the `case` rather than a coalesce is load-bearing. jsonb_array_elements_text
      -- yields zero rows for an absent key, so array() is '{}' and NOT null; coalesce would
      -- therefore take '{}' over mi.tags and clear the tags of every item on every unrelated edit.
      tags        = case when p_patch ? 'tags'
                          then array(select jsonb_array_elements_text(p_patch->'tags'))
                          else mi.tags end,
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

-- =============================================================================================
-- Assertions
-- =============================================================================================
-- 027's assertion 8 had a negative test because three earlier versions of its regex matched
-- nothing and were each shipped by a green run. The same discipline applies to assertion 1 below.
do $$
declare
  v_selfref text;
  v_body text;
  v_bad_tags text;
  v_unpinned text;
  v_opt_flag text;
  v_n integer;
  v_tags text;
  v_admin uuid;
  v_cat uuid;
  v_fixed uuid;
  v_opt uuid;
begin
  -- ---------------------------------------------------------------------------------------------
  -- 1. NO POLICY IN THE DATABASE REFERENCES ITS OWN TABLE. This is the general form of defect 2,
  --    and it is stated over pg_policies rather than over this one table so the next migration to
  --    write a recursive policy fails here instead of in a customer's face.
  --
  --    A self-reference renders as the table name followed by an alias inside its own qual, as in
  --    `FROM item_options io`. The lookbehind is what stops `menu_item_sizes.item_id` from
  --    counting: a qualified column reference always has a dot in front of the name.
  -- ---------------------------------------------------------------------------------------------
  select string_agg(tablename || '.' || policyname, ', ' order by tablename, policyname)
    into v_selfref
    from pg_policies
   where schemaname = 'public'
     and qual is not null
     and qual ~* ('(?<![[:alnum:]_.])' || tablename || '[[:space:]]+[[:alpha:]_]+');

  if v_selfref is not null then
    raise exception
      'FAIL CLOSED: these policies name their own table in their own USING expression, which PostgreSQL refuses to plan (42P17 infinite recursion detected in policy): %',
      v_selfref;
  end if;

  --    The negative test, in both directions. Assertion 1 is a claim about a regex, and a regex
  --    that cannot fail is not a check.
  --
  --    The positive probe is deliberately UNQUALIFIED. PostgreSQL renders a policy's qual against
  --    the search_path, so a real self-reference appears as `FROM (item_options io JOIN ...)` with
  --    no schema prefix - and the lookbehind rejects the qualified spelling, because a dot in
  --    front of the name is exactly the signal that it is a column reference and not a FROM item.
  --    Writing the probe as `public.item_options io` therefore fails to match its own pattern; that
  --    was the first version, and it failed closed on the dry run.
  if '(item_options io join public.menu_items mi on mi.id = io.item_id)'
       !~* '(?<![[:alnum:]_.])item_options[[:space:]]+[[:alpha:]_]+' then
    raise exception
      'FAIL CLOSED: the self-reference check cannot detect a self-referencing policy, so assertion 1 proves nothing';
  end if;
  if '(select 1 from public.menu_items mi where mi.id = menu_item_sizes.item_id)'
       ~* '(?<![[:alnum:]_.])menu_item_sizes[[:space:]]+[[:alpha:]_]+' then
    raise exception
      'FAIL CLOSED: the self-reference check false-positives on a qualified column reference, so it would block correct code';
  end if;

  -- ---------------------------------------------------------------------------------------------
  -- 2. `admin_upsert_menu_item_v1` reads `tags` through jsonb_array_elements_text and casts
  --    nothing out of p_patch into text[]. Positive AND negative, because the negative alone
  --    could be satisfied by deleting the feature.
  -- ---------------------------------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into v_body
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_upsert_menu_item_v1';
  if v_body is null then
    raise exception 'FAIL CLOSED: admin_upsert_menu_item_v1 does not exist';
  end if;

  select string_agg(m[1], ', ' order by m[1]) into v_bad_tags
    from regexp_matches(v_body, '\(p_patch->[^)]*\)\s*::\s*[a-z_]+\[\]', 'gi') m;
  if v_bad_tags is not null then
    raise exception
      'FAIL CLOSED: admin_upsert_menu_item_v1 casts p_patch straight into an array type. There is no jsonb -> text[] cast in PostgreSQL, so the function raises on every call: %',
      v_bad_tags;
  end if;

  if v_body !~* 'jsonb_array_elements_text' then
    raise exception
      'FAIL CLOSED: admin_upsert_menu_item_v1 does not read tags via jsonb_array_elements_text, so tags cannot be written at all';
  end if;

  --    Same negative-test discipline. `coalesce((p_patch->''tags'')::text[], ''{}''::text[])` is the
  --    exact text 027 shipped, and must still be detected.
  if 'coalesce((p_patch->''tags'')::text[], ''{}''::text[])' !~ '\(p_patch->[^)]*\)\s*::\s*[a-z_]+\[\]' then
    raise exception
      'FAIL CLOSED: the array-cast check cannot detect the defect 027 shipped, so assertion 2 proves nothing';
  end if;

  -- ---------------------------------------------------------------------------------------------
  -- 3. EXECUTE THE POLICY. This is the assertion 027 did not have.
  --
  --    `027` asserted that item_options_read's qual mentioned `is_available` and `deleted_at`. It
  --    did, and the policy still raised 42P17 on every SELECT. Reading the text of a policy proves
  --    only that it was written down; the only thing that proves it works is running it. So: switch
  --    to a client role, actually issue the SELECT, and fail if the planner refuses.
  --
  --    `pg_temp` is not used and no fixture is created. The catalog tables are empty at migration
  --    time, so `count(*)` is 0; the assertion is that the statement returns rather than raising.
  --    option_choices is included because it is the table that broke through no fault of its own.
  -- ---------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims', '', true);
  execute 'set local role authenticated';
  begin
    select count(*) into v_n from public.item_options;
    select count(*) into v_n from public.option_choices;
  exception when others then
    execute 'reset role';
    raise exception
      'FAIL CLOSED: a signed-in client still cannot read the catalog: %', sqlerrm;
  end;
  execute 'reset role';

  -- ---------------------------------------------------------------------------------------------
  -- 4. EXECUTE THE FUNCTION. The other half of the same lesson, and the reason assertion 2 is not
  --    trusted on its own.
  --
  --    A real admin, a real vendor, a real category and a real item, all created inside a
  --    subtransaction that is rolled back by raising a sentinel at the end. `raise exception`
  --    inside a plpgsql block unwinds to the implicit savepoint, so the fixture does not survive
  --    and the migration still leaves the database exactly as it found it. If the function raises
  --    for any reason OTHER than the sentinel, that error is re-raised and the migration fails.
  --
  --    The probe seeds its own vendor rather than borrowing one, because a probe that quietly
  --    skips when the table it needs is empty is a fail-open, and a fail-open in an assertion is
  --    the exact defect this migration exists to remove. It is unconditional by construction.
  -- ---------------------------------------------------------------------------------------------
  v_admin := gen_random_uuid();
  begin
    insert into auth.users (id, email, phone, raw_user_meta_data, created_at)
    values (v_admin, '027a-probe@test.local', '+20199990001', '{}'::jsonb, now());
    insert into public.user_roles (user_id, role) values (v_admin, 'admin');
    perform set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);

    insert into public.cities (code, name, name_ar, country_code, timezone, center_lat, center_lng)
    values ('P' || substr(v_admin::text, 1, 5), '027a probe', '027a probe', 'EG', 'Africa/Cairo', 30.0, 31.2);
    insert into public.areas (city_id, slug, name, name_ar, geohash_prefix, center_lat, center_lng)
    select c.id, 'p-' || substr(v_admin::text, 1, 5), '027a probe', '027a probe', 'u4pr', 30.0, 31.2
      from public.cities c where c.code = 'P' || substr(v_admin::text, 1, 5);
    insert into public.vendors (slug, name, name_ar, vertical_type, city_id, area_id,
                                latitude, longitude, geohash_prefix, is_approved, is_active)
    select 'p-' || substr(v_admin::text, 1, 5), '027a probe', '027a probe', 'food',
           c.id, a.id, 30.0, 31.2, 'u4pr', true, true
      from public.cities c
      join public.areas a on a.city_id = c.id
     where c.code = 'P' || substr(v_admin::text, 1, 5);

    v_cat := public.admin_upsert_menu_category_v1(
      jsonb_build_object(
        'vendor_id', (select v.id from public.vendors v where v.slug = 'p-' || substr(v_admin::text, 1, 5)),
        'name', '027a probe category'));
    if v_cat is null then
      raise exception 'FAIL CLOSED: the probe could not create a category, so nothing below was proved';
    end if;

    v_fixed := public.admin_upsert_menu_item_v1(
      jsonb_build_object('category_id', v_cat, 'name', 'Probe fixed',
                         'base_price', 250, 'tags', jsonb_build_array('probe', 'tags')));
    if v_fixed is null then
      raise exception 'FAIL CLOSED: admin_upsert_menu_item_v1 returned no id';
    end if;

    select array_to_string(mi.tags, ',') into v_tags from public.menu_items mi where mi.id = v_fixed;
    if v_tags is distinct from 'probe,tags' then
      raise exception
        'FAIL CLOSED: tags did not survive the write. Got %, expected probe,tags', coalesce(v_tags, '<null>');
    end if;

    -- an update that does not mention tags must not clear them
    perform public.admin_upsert_menu_item_v1(jsonb_build_object('description', 'probe'), v_fixed);
    select array_to_string(mi.tags, ',') into v_tags from public.menu_items mi where mi.id = v_fixed;
    if v_tags is distinct from 'probe,tags' then
      raise exception
        'FAIL CLOSED: an update without a tags key cleared the tags. Got %, expected probe,tags',
        coalesce(v_tags, '<null>');
    end if;

    -- an explicit [] must clear them.
    --
    -- cardinality, not array_length and not array_to_string. Both of those were tried here and
    -- both were wrong in opposite directions: array_to_string renders `{}` as the empty STRING, so
    -- a coalesce against a sentinel never fires; array_length returns NULL for `{}` rather than 0,
    -- so a coalesce against 0 never fires either. cardinality('{}') is 0 and cardinality(NULL) is
    -- NULL, which is the one rendering that distinguishes cleared from absent. An assertion that
    -- cannot tell those two apart passes for the wrong reason.
    perform public.admin_upsert_menu_item_v1('{"tags":[]}'::jsonb, v_fixed);
    select coalesce(cardinality(mi.tags), -1) into v_n from public.menu_items mi where mi.id = v_fixed;
    if v_n <> 0 then
      raise exception
        'FAIL CLOSED: tags = [] did not clear the column. cardinality returned %, expected 0', v_n;
    end if;

    -- the options and choices path, because defect 2 took option_choices down with it
    v_opt := public.admin_upsert_item_option_v1(jsonb_build_object('item_id', v_fixed, 'name', 'Probe option'));
    if v_opt is null then
      raise exception 'FAIL CLOSED: admin_upsert_item_option_v1 returned no id';
    end if;
    if public.admin_upsert_option_choice_v1(
         jsonb_build_object('option_id', v_opt, 'name', 'Probe choice')) is null then
      raise exception 'FAIL CLOSED: admin_upsert_option_choice_v1 returned no id';
    end if;

    raise exception 'ROLLBACK_PROBE';
  exception when others then
    if sqlerrm <> 'ROLLBACK_PROBE' then
      raise;
    end if;
  end;

  --    And prove the rollback actually happened, rather than trusting it. A probe that leaked its
  --    fixture would be a worse defect than the two this file fixes, and "the sentinel was raised"
  --    is a claim about intent rather than about the database.
  if (select count(*) from public.cities    where code = 'P' || substr(v_admin::text, 1, 5)) <> 0
     or (select count(*) from public.areas  where slug  = 'p-' || substr(v_admin::text, 1, 5)) <> 0
     or (select count(*) from public.vendors where slug  = 'p-' || substr(v_admin::text, 1, 5)) <> 0
     or (select count(*) from public.menu_categories where name = '027a probe category') <> 0
     or (select count(*) from public.menu_items where name = 'Probe fixed') <> 0
     or (select count(*) from public.users   where email = '027a-probe@test.local') <> 0
  then
    raise exception
      'FAIL CLOSED: the assertion-4 probe leaked its fixture. The sentinel rollback did not hold.';
  end if;

  -- ---------------------------------------------------------------------------------------------
  -- 5. The postconditions this file is not allowed to break while fixing the two above. All of
  --    them were already true of 027 and must stay true.
  -- ---------------------------------------------------------------------------------------------
  select not p.prosecdef or not exists (
           select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) cfg where cfg like 'search\_path=%')
    into v_unpinned
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_upsert_menu_item_v1';
  if v_unpinned then
    raise exception
      'FAIL CLOSED: admin_upsert_menu_item_v1 is no longer SECURITY DEFINER with a pinned search_path';
  end if;

  if has_function_privilege('anon', 'public.admin_upsert_menu_item_v1(jsonb,uuid)', 'EXECUTE')
     or has_function_privilege('public', 'public.admin_upsert_menu_item_v1(jsonb,uuid)', 'EXECUTE') then
    raise exception 'FAIL CLOSED: anon or PUBLIC can EXECUTE admin_upsert_menu_item_v1';
  end if;
  if not has_function_privilege('authenticated', 'public.admin_upsert_menu_item_v1(jsonb,uuid)', 'EXECUTE') then
    raise exception 'FAIL CLOSED: authenticated cannot execute admin_upsert_menu_item_v1';
  end if;

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
                     and qual ilike '%is_available%' and qual ilike '%deleted_at%') then
    raise exception
      'FAIL CLOSED: item_options_read does not filter on is_available and deleted_at, so a soft delete stays visible to customers';
  end if;
end $$;
