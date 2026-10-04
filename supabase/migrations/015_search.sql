-- =============================================================================================
-- 015_search.sql
-- =============================================================================================
-- Arabic-aware catalog search: normalisation, normalised stored columns, trigram indexes, and the
-- search RPC.
--
-- WHY NORMALISATION HAS TO COME FIRST. data-model.md §5 says plainly that "an index on raw
-- lower(name) would never be used by that query". A customer searching مشويات types the alef without
-- hamza; the row stores أ. A customer searching شاورما types the taa marbuta; the row stores ة. Both
-- miss. So the index is built on a folded form, not on the raw text.
--
-- WHY THIS FUNCTION IS IMMUTABLE, AND WHY THAT CONSTRAINS THE IMPLEMENTATION.
-- A GENERATED ... STORED column may only call immutable functions, and so may an index expression.
-- PostgreSQL enforces this at DDL time, so it is a hard constraint rather than a preference.
--
-- `extensions.unaccent` CANNOT BE USED HERE. On this project it is STABLE, not IMMUTABLE, because
-- the dictionary is configuration that can be reloaded. Verified before writing. A STABLE function in
-- a generated column is rejected outright, so Latin folding is hand-rolled below. unaccent remains
-- correct and useful for ad-hoc `ILIKE` queries; it is simply not indexable material.
--
-- translate() IS USED FOR FOLDS RATHER THAN A replace() CHAIN, because it maps a whole character
-- set in one pass. Its one constraint is that correspondence is positional from the start of both
-- strings and characters at the END of `from` with no counterpart in `to` are deleted - which is
-- exactly the shape needed here: real folds first, deletions last.
--
-- MAINTENANCE WARNING, AND IT IS A REAL ONE. Changing public.normalize_text_v1 does NOT recompute
-- existing rows in a GENERATED STORED column - PostgreSQL stores the computed value, not the
-- expression. A change to the folding rules therefore requires an explicit backfill of every
-- normalised column, or search silently keeps matching the old rules. Recorded here because it is not
-- obvious and will bite whoever tunes the Arabic folding.
-- =============================================================================================

-- =============================================================================================
-- normalisation
-- =============================================================================================
-- The to-string is built with repeat() rather than a typed-out run of letters. An earlier draft typed
-- both strings literally and the from-string turned out to be one character SHORTER than the to-string
-- in the first group, which silently shifted every mapping after it: e-acute folded to `a`, n-tilde to
-- `u`, and Arabic alef-with-hamza to `c`. It still ran, and still returned plausible-looking text.
-- repeat() derives the target length from the intent, so the two cannot drift apart. The surplus is
-- asserted at the end of this migration.
create or replace function public.normalize_text_v1(p_text text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select btrim(regexp_replace(
    translate(
      replace(
        replace(
          replace(lower(coalesce(p_text, '')), 'ß', 'ss'),
          'æ', 'ae'),
        'œ', 'oe'),
      -- from-string. Alignment with the to-string below is positional, so anything in here that has no
      -- counterpart there is DELETED - which is how the tail of this string removes tashkeel.
      'áàâäãåāăą' || 'éèêëēĕėęě' || 'íìîïīĭįı' || 'óòôöõōŏő' ||
      'úùûüūŭůűų' || 'ñńņňŉ' || 'çćĉċč' || 'ýÿŷ' ||
      'آأإٱ' || 'ؤ' || 'ئى' || 'ة' ||
      '٠١٢٣٤٥٦٧٨٩' || '،' ||
      'ء' || 'ـ' || 'ً' || 'ٌ' || 'ٍ' || 'َ' || 'ُ' || 'ِ' || 'ّ' || 'ْ' || 'ٰ',
      repeat('a',9) || repeat('e',9) || repeat('i',8) || repeat('o',8) || repeat('u',9) ||
      repeat('n',5) || repeat('c',5) || repeat('y',3) ||
      repeat('ا',4) || 'و' || repeat('ي',2) || 'ه' ||
      '0123456789' || ' '
    ),
    '\s+', ' ', 'g'
  ))
$$;

revoke execute on function public.normalize_text_v1(text) from public, anon;

-- jsonb overload. `menu_items.ingredients` is jsonb and NO SHAPE FOR IT IS SPECIFIED ANYWHERE in
-- data-model.md or contracts.md - it could be ["دجاج","بصل"], {"main":"دجاج"}, or a single string.
-- Rather than bet on one shape, this flattens all three mechanically: arrays join their elements,
-- objects join their values, a string is unwrapped, anything else takes its text form.
--
-- Recorded as an open assumption rather than a decision. If ingredients turns out to be an object whose
-- KEYS are the searchable part ("chicken": 3), this would normalise the values instead and the search
-- would silently match nothing - which is why the assumption is written down here rather than left
-- implicit in a CASE.
create or replace function public.normalize_text_v1(p_value jsonb)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select public.normalize_text_v1(
    case jsonb_typeof(p_value)
      when 'array'  then (select coalesce(string_agg(e.value, ' '), '')
                          from jsonb_array_elements_text(p_value) e)
      when 'object' then (select coalesce(string_agg(e.value, ' '), '')
                          from jsonb_each_text(p_value) e)
      when 'string' then btrim(p_value::text, '"')
      else p_value::text
    end);
$$;

revoke execute on function public.normalize_text_v1(jsonb) from public, anon;

-- =============================================================================================
-- great-circle distance
-- =============================================================================================
-- Not created before 015 and not invented here for one call site: contracts.md 1.2 names distance as
-- a tie-breaker for search, and free-tier-plan.md's fee model needs the same number for per_km_fee.
-- One function, both callers. Reusing it is the point.
--
-- The least/greatest clamp is load-bearing. acos() raises on a domain error when floating-point drift
-- pushes its argument a hair outside [-1, 1], which happens near-antipodal points - and a search that
-- errors instead of returning nothing is worse than one that returns everything.
--
-- 6371 is the mean Earth radius in km. It is a physical constant, not a business one, so it is not
-- configuration under constitution rule 7 - which governs money.
create or replace function public.haversine_km(
  p_lat1 numeric, p_lng1 numeric, p_lat2 numeric, p_lng2 numeric
)
returns numeric
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case
    when p_lat1 is null or p_lng1 is null or p_lat2 is null or p_lng2 is null then null
    else round((
      6371 * acos(least(1, greatest(-1,
        sin(radians(p_lat1)) * sin(radians(p_lat2))
        + cos(radians(p_lat1)) * cos(radians(p_lat2)) * cos(radians(p_lng1 - p_lng2))
      )))
    )::numeric, 3)
  end
$$;

revoke execute on function public.haversine_km(numeric, numeric, numeric, numeric) from public, anon;

-- =============================================================================================
-- normalised stored columns
-- =============================================================================================
-- STORED rather than expression indexes, because the RPC both filters and RANKS on these values, so
-- it wants to read them as a column rather than recompute the fold per row. The trade is storage plus
-- a fold on every write; menu edits are rare and reads are hot, so that is the right way round.
--
-- ADD COLUMN with an immutable expression is metadata-only in PostgreSQL 11+ - no table rewrite - so
-- this is a brief lock on small tables, not a rebuild.

alter table public.vendors
  add column name_normalized        text generated always as (public.normalize_text_v1(name)) stored,
  add column name_ar_normalized     text generated always as (public.normalize_text_v1(name_ar)) stored,
  add column description_normalized text generated always as (public.normalize_text_v1(description)) stored;

alter table public.menu_categories
  add column name_normalized    text generated always as (public.normalize_text_v1(name)) stored,
  add column name_ar_normalized text generated always as (public.normalize_text_v1(name_ar)) stored;

alter table public.menu_items
  add column name_normalized        text generated always as (public.normalize_text_v1(name)) stored,
  add column name_ar_normalized     text generated always as (public.normalize_text_v1(name_ar)) stored,
  add column ingredients_normalized text generated always as (public.normalize_text_v1(ingredients)) stored;

-- `tags text[]` is deliberately NOT indexed. Casting an array to text is not immutable, so it cannot
-- go in a generated column, and a fourth trigram index on the largest catalog table is not worth a
-- bespoke immutability wrapper for tags that are admin metadata rather than customer-facing copy.
-- Recorded so the omission reads as a decision rather than an oversight.
alter table public.cuisines
  add column name_normalized    text generated always as (public.normalize_text_v1(name)) stored,
  add column name_ar_normalized text generated always as (public.normalize_text_v1(name_ar)) stored;

-- =============================================================================================
-- trigram indexes
-- =============================================================================================
-- pg_trgm is already installed by 001 and lives in the `extensions` schema, hence `extensions.gin_trgm_ops`.
--
-- A trigram index can only accelerate a pattern of three characters or more, because that is the
-- length of the unit it stores. Queries shorter than that cannot use it, which is why
-- search_catalog_v1 has a separate non-indexed path rather than pretending one index serves
-- everything.
--
-- Partial on live rows only. A deactivated vendor or a soft-deleted dish is not searchable, and
-- `014` already denies clients those rows, so indexing them would be index bloat for results nobody
-- may see.
create index vendors_name_trgm on public.vendors
  using gin (name_normalized extensions.gin_trgm_ops)
  where is_active and is_approved and deleted_at is null;

create index vendors_name_ar_trgm on public.vendors
  using gin (name_ar_normalized extensions.gin_trgm_ops)
  where is_active and is_approved and deleted_at is null;

create index vendors_description_trgm on public.vendors
  using gin (description_normalized extensions.gin_trgm_ops)
  where is_active and is_approved and deleted_at is null;

create index menu_categories_name_trgm on public.menu_categories
  using gin (name_normalized extensions.gin_trgm_ops)
  where is_available and deleted_at is null;

create index menu_categories_name_ar_trgm on public.menu_categories
  using gin (name_ar_normalized extensions.gin_trgm_ops)
  where is_available and deleted_at is null;

create index menu_items_name_trgm on public.menu_items
  using gin (name_normalized extensions.gin_trgm_ops)
  where is_available and deleted_at is null;

create index menu_items_name_ar_trgm on public.menu_items
  using gin (name_ar_normalized extensions.gin_trgm_ops)
  where is_available and deleted_at is null;

create index menu_items_ingredients_trgm on public.menu_items
  using gin (ingredients_normalized extensions.gin_trgm_ops)
  where is_available and deleted_at is null;

create index cuisines_name_trgm on public.cuisines
  using gin (name_normalized extensions.gin_trgm_ops);

create index cuisines_name_ar_trgm on public.cuisines
  using gin (name_ar_normalized extensions.gin_trgm_ops);

-- =============================================================================================
-- search_catalog_v1
-- =============================================================================================
-- Signature fixed by contracts.md 1.2:
--   search_catalog_v1(p_query text, p_area_id uuid, p_filters jsonb, p_limit int)
--   -> ranked merchants + items; "trigram similarity; open-now and distance as tie-breakers".
--
-- SECURITY DEFINER, so it must REPLICATE the visibility rules rather than inherit them. SECURITY
-- DEFINER bypasses RLS, which means every predicate `014` enforces is this function's responsibility
-- now. Omitting one here would be a leak that no policy could catch, so the same three conditions as
-- `vendors_read` and `menu_items_read` are re-stated explicitly: an active, approved, non-deleted
-- vendor, and an available, non-deleted item belonging to one.
--
-- The area filter is an EXISTS against vendor_areas rather than a join, because one vendor serves many
-- areas and a join would multiply vendor rows once per area served before the limit is applied.
--
-- Filters honoured, all optional and all read from p_filters: cuisine_ids (uuid[]), vertical_type
-- (text), open_now (boolean), max_price (piastres, item price only). Anything else in p_filters is
-- ignored rather than rejected, so a newer client sending an extra key gets results rather than an
-- error.
create or replace function public.search_catalog_v1(
  p_query    text,
  p_area_id  uuid default null,
  p_filters  jsonb default '{}'::jsonb,
  p_limit    int   default 20
)
returns table (
  kind                 text,
  vendor_id            uuid,
  vendor_name          text,
  vendor_name_ar       text,
  item_id              uuid,
  item_category_id     uuid,
  item_name            text,
  item_name_ar         text,
  item_image_path      text,
  item_price           integer,
  score                numeric,
  is_open              boolean,
  distance_km          numeric,
  rating_avg           numeric,
  rating_count         integer,
  minimum_order_value  integer,
  prep_time_minutes    integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q       text := public.normalize_text_v1(p_query);
  v_limit   int  := greatest(1, least(coalesce(p_limit, 20), 50));
  v_area_lat numeric;
  v_area_lng numeric;
begin
  if p_area_id is not null then
    select a.center_lat, a.center_lng into v_area_lat, v_area_lng
    from public.areas a where a.id = p_area_id;
  end if;

  -- Empty or whitespace-only query is BROWSE, not a search. Returning similarity-ranked nonsense for
  -- an empty box would be worse than showing the good local vendors, so this path ignores the query
  -- entirely and ranks by open-then-rating.
  if v_q = '' then
    return query
    select
      'vendor'::text, v.id, v.name, v.name_ar,
      null::uuid, null::uuid, null::text, null::text, v.logo_path,
      null::integer,
      v.rating_avg::numeric,
      v.is_open,
      public.haversine_km(v.latitude, v.longitude, v_area_lat, v_area_lng),
      v.rating_avg, v.rating_count, v.minimum_order_value, v.prep_time_minutes
    from public.vendors v
    where v.is_active and v.is_approved and v.deleted_at is null
      and (p_area_id is null or exists (
            select 1 from public.vendor_areas va
             where va.vendor_id = v.id and va.area_id = p_area_id and va.is_active))
      and (not coalesce((p_filters->>'open_now')::boolean, false) or v.is_open)
      and (p_filters->>'vertical_type' is null or v.vertical_type = p_filters->>'vertical_type')
      and (p_filters->>'max_price' is null
           or v.minimum_order_value <= (p_filters->>'max_price')::integer)
    order by v.is_open desc, v.rating_avg desc, v.rating_count desc
    limit v_limit;
    return;
  end if;

  -- >= 3 characters: the LIKE '%..%' form is what the trigram indexes accelerate.
  if char_length(v_q) >= 3 then
    return query
    with ranked as (
      select
        'vendor'::text as kind, v.id as vendor_id, v.name as vendor_name, v.name_ar as vendor_name_ar,
        null::uuid as item_id, null::uuid as item_category_id,
        null::text as item_name, null::text as item_name_ar, v.logo_path as item_image_path,
        null::integer as item_price,
        greatest(
          extensions.similarity(v.name_normalized, v_q),
          extensions.similarity(v.name_ar_normalized, v_q),
          extensions.similarity(v.description_normalized, v_q) * 0.6
        ) as score,
        v.is_open, v.latitude, v.longitude, v.rating_avg, v.rating_count,
        v.minimum_order_value, v.prep_time_minutes
      from public.vendors v
      where v.is_active and v.is_approved and v.deleted_at is null
        and (v.name_normalized like '%' || v_q || '%'
             or v.name_ar_normalized like '%' || v_q || '%'
             or v.description_normalized like '%' || v_q || '%')
        and (p_area_id is null or exists (
              select 1 from public.vendor_areas va
               where va.vendor_id = v.id and va.area_id = p_area_id and va.is_active))
        and (not coalesce((p_filters->>'open_now')::boolean, false) or v.is_open)
        and (p_filters->>'vertical_type' is null or v.vertical_type = p_filters->>'vertical_type')
        and (p_filters->>'max_price' is null
             or v.minimum_order_value <= (p_filters->>'max_price')::integer)

      union all

      select
        'item'::text, v.id, v.name, v.name_ar,
        mi.id, mc.id, mi.name, mi.name_ar, mi.image_path, mi.base_price,
        greatest(
          extensions.similarity(mi.name_normalized, v_q),
          extensions.similarity(mi.name_ar_normalized, v_q),
          extensions.similarity(mi.ingredients_normalized, v_q) * 0.5
        ) as score,
        v.is_open, v.latitude, v.longitude, v.rating_avg, v.rating_count,
        v.minimum_order_value, v.prep_time_minutes
      from public.menu_items mi
      join public.menu_categories mc on mc.id = mi.category_id
      join public.vendors v on v.id = mi.vendor_id
      where mi.is_available and mi.deleted_at is null
        and mc.is_available and mc.deleted_at is null
        and v.is_active and v.is_approved and v.deleted_at is null
        and (mi.name_normalized like '%' || v_q || '%'
             or mi.name_ar_normalized like '%' || v_q || '%'
             or mi.ingredients_normalized like '%' || v_q || '%')
        and (p_area_id is null or exists (
              select 1 from public.vendor_areas va
               where va.vendor_id = v.id and va.area_id = p_area_id and va.is_active))
        and (not coalesce((p_filters->>'open_now')::boolean, false) or v.is_open)
        and (p_filters->>'vertical_type' is null or v.vertical_type = p_filters->>'vertical_type')
        and (p_filters->>'cuisine_ids' is null or exists (
              select 1 from public.vendor_cuisines vc
               where vc.vendor_id = v.id
                 and vc.cuisine_id = any (select jsonb_array_elements_text(p_filters->'cuisine_ids')::uuid)))
        and (p_filters->>'max_price' is null
             or mi.base_price <= (p_filters->>'max_price')::integer)
    )
    select r.kind, r.vendor_id, r.vendor_name, r.vendor_name_ar,
           r.item_id, r.item_category_id, r.item_name, r.item_name_ar, r.item_image_path, r.item_price,
           round(r.score::numeric, 4),
           r.is_open,
           public.haversine_km(r.latitude, r.longitude, v_area_lat, v_area_lng),
           r.rating_avg, r.rating_count, r.minimum_order_value, r.prep_time_minutes
    from ranked r
    order by r.score desc, r.is_open desc,
             public.haversine_km(r.latitude, r.longitude, v_area_lat, v_area_lng) asc nulls last
    limit v_limit;
    return;
  end if;

  -- 1-2 characters: a trigram index cannot help, because it stores three-character units. This is a
  -- sequential scan and that is a deliberate, recorded trade rather than an oversight - at 150 vendors
  -- and roughly 4,500 items the scan is cheap, and it would need a prefix btree index to matter. The
  -- alternative is paying for an index on every normalised column to serve two-character queries.
  return query
  with ranked as (
    select 'vendor'::text as kind, v.id as vendor_id, v.name as vendor_name, v.name_ar as vendor_name_ar,
           null::uuid as item_id, null::uuid as item_category_id,
           null::text as item_name, null::text as item_name_ar, v.logo_path as item_image_path,
           null::integer as item_price, 1::numeric as score,
           v.is_open, v.latitude, v.longitude, v.rating_avg, v.rating_count,
           v.minimum_order_value, v.prep_time_minutes
    from public.vendors v
    where v.is_active and v.is_approved and v.deleted_at is null
      and (position(v_q in v.name_normalized) > 0
           or position(v_q in v.name_ar_normalized) > 0)
      and (p_area_id is null or exists (
            select 1 from public.vendor_areas va
             where va.vendor_id = v.id and va.area_id = p_area_id and va.is_active))

    union all

    select 'item'::text, v.id, v.name, v.name_ar,
           mi.id, mc.id, mi.name, mi.name_ar, mi.image_path, mi.base_price, 1::numeric,
           v.is_open, v.latitude, v.longitude, v.rating_avg, v.rating_count,
           v.minimum_order_value, v.prep_time_minutes
    from public.menu_items mi
    join public.menu_categories mc on mc.id = mi.category_id
    join public.vendors v on v.id = mi.vendor_id
    where mi.is_available and mi.deleted_at is null
      and mc.is_available and mc.deleted_at is null
      and v.is_active and v.is_approved and v.deleted_at is null
      and (position(v_q in mi.name_normalized) > 0
           or position(v_q in mi.name_ar_normalized) > 0)
      and (p_area_id is null or exists (
            select 1 from public.vendor_areas va
             where va.vendor_id = v.id and va.area_id = p_area_id and va.is_active))
  )
  select r.kind, r.vendor_id, r.vendor_name, r.vendor_name_ar,
         r.item_id, r.item_category_id, r.item_name, r.item_name_ar, r.item_image_path, r.item_price,
         r.score, r.is_open,
         public.haversine_km(r.latitude, r.longitude, v_area_lat, v_area_lng),
         r.rating_avg, r.rating_count, r.minimum_order_value, r.prep_time_minutes
  from ranked r
  order by r.is_open desc,
           public.haversine_km(r.latitude, r.longitude, v_area_lat, v_area_lng) asc nulls last
  limit v_limit;
end $$;

grant  execute on function public.search_catalog_v1(text, uuid, jsonb, int) to authenticated;
revoke execute on function public.search_catalog_v1(text, uuid, jsonb, int) from public, anon;

-- =============================================================================================
-- fail closed
-- =============================================================================================
-- A generated column whose expression is STABLE rather than IMMUTABLE would have been rejected at
-- DDL time, so its existence proves the folding function is indexable. What can still go wrong
-- silently is the normalised column not existing at all, which would leave the trigram indexes
-- unqueryable and search returning nothing forever.
do $$
declare missing text; r record; d int;
begin
  select string_agg(t || '.' || col, ', ') into missing
  from (values
      ('vendors','name_normalized'), ('vendors','name_ar_normalized'), ('vendors','description_normalized'),
      ('menu_categories','name_normalized'), ('menu_categories','name_ar_normalized'),
      ('menu_items','name_normalized'), ('menu_items','name_ar_normalized'), ('menu_items','ingredients_normalized'),
      ('cuisines','name_normalized'), ('cuisines','name_ar_normalized')
  ) as want(t, col)
  where not exists (
    select 1 from pg_attribute
    where attrelid = format('public.%I', want.t)::regclass
      and attname = want.col and attgenerated = 's' and not attisdropped
  );

  if missing is not null then
    raise exception 'FAIL CLOSED: normalised columns missing or not generated: %', missing;
  end if;

  -- Every fold and every deletion, asserted BEHAVIOURALLY against the real function.
  --
  -- An earlier draft of this migration asserted the LENGTH DIFFERENCE between translate()'s two
  -- strings via a helper. That was the wrong design and it caught itself: the helper re-typed the
  -- character strings, the two copies drifted by one character, and the assertion failed on correct
  -- code. A guard that duplicates the thing it guards is a second source of truth, not a check. These
  -- assertions call the function and compare its output, so they cannot drift from it.
  --
  -- Codepoints rather than literals, for the same reason: hand-typed Arabic is exactly what produced
  -- the original bug, and an assertion you cannot type reliably is an assertion you will get wrong.
  for r in
    select * from (values
      (1571, 1575),   -- U+0623 alef with hamza above  -> U+0627
      (1570, 1575),   -- U+0622 alef with madda above -> U+0627
      (1573, 1575),   -- U+0625 alef with hamza below -> U+0627
      (1649, 1575),   -- U+0671 alef wasla            -> U+0627
      (1572, 1608),   -- U+0624 waw with hamza       -> U+0648
      (1574, 1610),   -- U+0626 yeh with hamza       -> U+064A
      (1609, 1610),   -- U+0649 alef maksura         -> U+064A
      (1577, 1607)    -- U+0629 teh marbuta          -> U+0647
    ) as t(src, want)
  loop
    if public.normalize_text_v1(chr(r.src)) <> chr(r.want) then
      raise exception 'FAIL CLOSED: U+% does not fold to U+% (got %)',
        r.src, r.want, public.normalize_text_v1(chr(r.src));
    end if;
  end loop;

  -- All eleven characters that must disappear entirely.
  for d in
    select unnest(array[1569, 1600, 1611, 1612, 1613, 1614, 1615, 1616, 1617, 1618, 1648])
  loop
    if public.normalize_text_v1(chr(d)) <> '' then
      raise exception 'FAIL CLOSED: U+% is not being stripped (got %)',
        d, public.normalize_text_v1(chr(d));
    end if;
  end loop;

  -- Latin folds, so a shift in the Latin half cannot pass unnoticed behind correct Arabic.
  if public.normalize_text_v1(chr(233)) <> 'e'    then raise exception 'FAIL CLOSED: e-acute'; end if;
  if public.normalize_text_v1(chr(241)) <> 'n'    then raise exception 'FAIL CLOSED: n-tilde'; end if;
  if public.normalize_text_v1(chr(252)) <> 'u'    then raise exception 'FAIL CLOSED: u-diaeresis'; end if;
  if public.normalize_text_v1(chr(231)) <> 'c'    then raise exception 'FAIL CLOSED: c-cedilla'; end if;
  if public.normalize_text_v1(chr(223)) <> 'ss'   then raise exception 'FAIL CLOSED: sharp s'; end if;
  if public.normalize_text_v1(chr(230)) <> 'ae'   then raise exception 'FAIL CLOSED: ae ligature'; end if;
  if public.normalize_text_v1(chr(339)) <> 'oe'   then raise exception 'FAIL CLOSED: oe ligature'; end if;

  -- Arabic-indic digits, and the comma. Wrapped in letters because a lone comma folds to a space which
  -- btrim then removes - correct, but it would make this assertion fail for the wrong reason.
  if public.normalize_text_v1(chr(1632)) <> '0' then raise exception 'FAIL CLOSED: arabic-indic 0'; end if;
  if public.normalize_text_v1(chr(1635)) <> '3' then raise exception 'FAIL CLOSED: arabic-indic 3'; end if;
  if public.normalize_text_v1('a' || chr(1548) || 'b') <> 'a b' then
    raise exception 'FAIL CLOSED: arabic comma does not become a separator';
  end if;

  -- The jsonb overload, which the ingredients column is generated from. Both shapes, plus the case
  -- where an object is keyed by ingredient name rather than value.
  if public.normalize_text_v1('["' || chr(1571) || chr(1581) || '"]'::jsonb) <> chr(1575) || chr(1581) then
    raise exception 'FAIL CLOSED: jsonb array ingredients not flattened';
  end if;
  if public.normalize_text_v1(jsonb_build_object('main', 'x')) <> 'x' then
    raise exception 'FAIL CLOSED: jsonb object ingredients not flattened';
  end if;

  -- normalize_text_v1 must stay immutable or every index built on it becomes invalid on the next
  -- dump/restore, which is a spectacularly confusing failure. Cheap to assert. Both overloads: the
  -- jsonb one is what the ingredients column is generated from.
  if (select provolatile from pg_proc
      where oid = 'public.normalize_text_v1(jsonb)'::regprocedure) <> 'i' then
    raise exception 'FAIL CLOSED: normalize_text_v1(jsonb) is not IMMUTABLE';
  end if;
  if (select provolatile from pg_proc
      where oid = 'public.normalize_text_v1(text)'::regprocedure) <> 'i' then
    raise exception 'FAIL CLOSED: normalize_text_v1 is not IMMUTABLE';
  end if;

  -- The distance helper must stay immutable too, for the same reason.
  if (select provolatile from pg_proc
      where oid = 'public.haversine_km(numeric,numeric,numeric,numeric)'::regprocedure) <> 'i' then
    raise exception 'FAIL CLOSED: haversine_km is not IMMUTABLE';
  end if;

  if has_function_privilege('anon', 'public.search_catalog_v1(text,uuid,jsonb,int)', 'execute') then
    raise exception 'FAIL CLOSED: anon can execute search_catalog_v1';
  end if;
end $$;
