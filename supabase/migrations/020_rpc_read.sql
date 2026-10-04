-- =============================================================================================
-- 020_rpc_read.sql
-- =============================================================================================
-- The five read RPCs: the customer feed, the vendor dashboard, earnings, admin metrics and flags.
--
-- =============================================================================================
-- WHY THIS FILE IS SHAPED BY BYTES AND NOT BY CONVENIENCE
-- =============================================================================================
-- free-tier-plan.md 4.1 prices this database at 390 MB/day of egress as naively built, of which
-- 275 MB is polling: order status 81 MB, rider availability 108 MB, vendor dashboard 86 MB. The
-- plan's answer is push-not-poll (4.2); the second half of the answer is that whatever IS read has
-- to be small. This file is that second half.
--
-- Three rules follow, and they are why several functions look narrower than a screen wants:
--
--   1. Every column is named. There is no `select *` and no `select alias.*` anywhere in this
--      file, and the fail-closed block asserts it. A new column added to `vendors` in migration 021
--      must be added here deliberately or not at all, because adding it silently multiplies its
--      cost by every customer's every feed load.
--   2. Nothing a client polls is time-varying. `p_open_only` filters and returns `vendors.is_open`,
--      the STORED manual override, not a schedule-derived is_open_now. A value that changes with the
--      clock cannot live in an R2 snapshot without going stale, and this feed IS the snapshot
--      source (contracts.md 1.1 calls it the cache-miss path). `get_vendor_detail_v1` is where
--      schedule-derived is_open_now belongs.
--   3. No money constant appears here and no computed price is returned. constitution I.1 puts
--      prices and fees in Postgres, never in a snapshot or a flag, so the feed carries NO delivery
--      fee: it is a zone rule plus a per-vendor tier resolved by `quote_order_v1`. The only
--      non-integer number any of these five functions returns is `rating_avg` (a 0-5 rating, not
--      money) and ETA minute offsets (minutes, not money). Every money column is integer piastres
--      (constitution I.3), and the fail-closed block asserts that no OUT parameter of any of these
--      functions is float, double precision or numeric.
--
-- Return shapes are `table (payload jsonb)` for the four heterogeneous responses and
-- `table (flag_key text, value jsonb)` for `get_flags_v1`, which data-model.md 1 specifies exactly.
-- The reason is shape, not laziness: three of these responses are an array PLUS a cursor or
-- per-account totals, and `returns table` cannot express that without repeating the cursor on
-- every row. The typed boundary is on the app side, where AGENTS.md A3 puts it (a Zod discriminated
-- union keyed on account_type / block name).
-- =============================================================================================
--
-- =============================================================================================
-- SECURITY DEFINER, AND WHAT THAT COSTS
-- =============================================================================================
-- SECURITY DEFINER bypasses RLS. Every predicate 014 enforces on a table this file reads must be
-- re-stated inside the function body, or it is a leak no policy can catch. This is not theoretical:
-- 014 shipped exactly that bug - vendor 1 could read vendor 2's sub-order line items on a shared
-- order - and 014a had to fix it in production after measuring 3 rows returned where 2 were
-- expected.
--
-- The predicate that stops a vendor reading a competitor is NEVER an id supplied by the client. It
-- is always `vendor_id in (select private.vendor_ids_for((select auth.uid())))`, derived from the
-- JWT. `get_vendor_dashboard_v1` accepts a `p_vendor_id` purely as a convenience filter and
-- intersects it with that set, so a caller asking for somebody else's vendor gets zero rows rather
-- than somebody else's revenue. The same rule governs riders via
-- `private.rider_ids_for((select auth.uid()))`. Both are re-checked at the bottom of this file so
-- the gate cannot be dropped without the migration failing.
--
-- `get_admin_metrics_v1` gates on `private.is_admin()` inside the body and raises NOT_AUTHORIZED
-- (contracts.md 5) rather than returning an empty result. An empty result would be
-- indistinguishable from a quiet Tuesday, and an admin console showing zero revenue during a bug is
-- worse than one showing an error.
--
-- `raise exception ... using errcode = 'P0001'` is written longhand rather than calling
-- `public.raise_app_error`, because that function is specced in contracts.md 5 and DOES NOT EXIST
-- in the database. Depending on it would make this migration fail at DDL time.
--
-- `(select auth.uid())`, never a bare `auth.uid()`. Migration 022 fails the build on a bare one
-- inside a policy; doing it correctly here means there is nothing for it to fail on.
--
-- =============================================================================================
-- BEHAVIOUR CHANGE FROM THE WRITTEN SPEC - READ THIS BEFORE REVIEWING ANYTHING ELSE
-- =============================================================================================
-- data-model.md 1 gives a sample `get_flags_v1` whose version gate is INERT. It reads
--
--     f.targeting_rules->'min_app_version'->>p_app_version
--
-- which uses a VERSION STRING AS A JSON KEY. `min_app_version` is keyed by PLATFORM
-- (`{"android":"1.4.0","ios":"1.4.0"}`), so that lookup is always NULL, coalesces to '', and the
-- surrounding `= ''` test is always true. The documented version gate therefore never fired, for
-- any client, at any version. It is a guarantee that existed only in the documentation.
--
-- This migration REPLACES it with a real comparison, via `public.semver_gte`. That is a change in
-- observable behaviour, not a refactor: a client below a targeted flag's `min_app_version` will now
-- STOP RECEIVING that flag, where before it received it unconditionally. Any flag that has ever
-- relied on `min_app_version` will change behaviour the first time this lands. That is the correct
-- outcome - a floor that does not fire is worse than no floor - but it is a behaviour change and it
-- is the single most important thing in this file for a reviewer to understand.
--
-- HOW THE GATE IS RESOLVED, AND WHY IT IS THE CONSERVATIVE WAY ROUND.
-- `get_flags_v1(p_app_role, p_app_version)` has NO platform parameter, and `min_app_version` is keyed
-- by platform. There is no way to ask "is this Android or iOS?" from inside the function. So the gate
-- is applied against EVERY minimum present in the object: a client below ANY platform's floor does
-- not get the flag.
--
-- This is a conservative choice made in the ABSENCE of A PLATFORM PARAMETER. It fails in one
-- direction only, and that direction is deliberate: it MASKS A FEATURE from an up-to-date client
-- whenever the Android and iOS floors differ - an iOS client on 1.5.0 loses a flag whose only
-- Android floor is 1.6.0. A rollout gate should be restrictive; showing a feature to a client too
-- old to handle it is the failure that costs money, while hiding a feature from a current client
-- costs a confused support ticket. The trade is taken in that direction on purpose.
--
-- THE REAL FIX IS A PLATFORM PARAMETER ON THE SIGNATURE, and that is a contracts.md amendment.
-- Adding one here would change a contract-specified signature from inside an implementation
-- migration, which is precisely what AGENTS.md rule 9 and rule 6 exist to prevent. It is recorded
-- as open question A8 below and left for the spec, not invented here. Until it exists, the
-- per-platform floor the app needs for its own force-update screen remains separately available as
-- the scalar flags `min_app_version_android` and `min_app_version_ios`.
-- =============================================================================================

-- =============================================================================================
-- ASSUMPTIONS. Every place the spec was silent, listed rather than silently decided.
-- =============================================================================================
-- A1. RESOLVED AGAINST data-model.md 15.2 ROW 020, IN FAVOUR OF contracts.md. Row 020 named a single
--     `get_earnings_v1`; contracts.md 1.6 line 127 names `get_vendor_earnings_v1(p_from, p_to)` and
--     1.7 line 147 names `get_rider_earnings_v1(p_from, p_to)`. contracts.md is the authoritative
--     document for RPC names and signatures, so the function has been split into the two
--     contract-named functions and `get_earnings_v1` does not exist anywhere in this file, not even
--     as an alias. Row 020 is the document that needs correcting.
-- A1b. `get_vendor_dashboard_v1` is an INTENTIONAL ADDITION FROM data-model.md 15.2 ROW 020, not an
--     invention and not a contradiction. It is absent from contracts.md rather than contradicted by
--     it, and a `contracts.md` row is being added for it by the maintainer. It is recorded here so
--     the next reader knows the absence is a known gap with an owner, not an oversight.
-- A2. `get_vendor_dashboard_v1(p_vendor_id uuid default null)`. Null returns one block per vendor
--     the caller staffs, because `vendor_staff` is many-to-many and one person may work at two
--     vendors. A non-null value is intersected with the JWT-derived set, never trusted.
-- A3. Both earnings functions take `(p_from date default null, p_to date default null)` and NOTHING
--     ELSE - no owner id, no owner type, no role. The account set is derived from the JWT inside each
--     function. Default window is the last 30 business days.
-- A4. Page ceiling. `p_limit` defaults to 12, not to the contract's maximum of 40: 40 vendors x
--     ~340 bytes is ~13.6 KB against an implied ~7.25 KB/session budget (29 MB/day / 4,000
--     sessions, free-tier-plan 4.1). 12 rows is ~4.1 KB. The 40 ceiling stands, because contracts.md
--     sets it as a maximum and does not forbid a lower default.
-- A5. `p_offset` is clamped at 2000 rather than rejected. contracts.md 5 has no PAGE_TOO_DEEP code
--     and inventing one is forbidden; clamping deterministically and reporting `has_more: false` at
--     the ceiling needs no new error. A caller paging past 2000 on a 150-vendor feed is a client bug.
-- A6. `p_sort` accepts exactly `rating` (default), `name`, `prep_time`, `min_order`.
--     Unrecognised values fall back to `rating` rather than erroring. contracts.md names no sort
--     vocabulary.
-- A7. `p_query` is one `like '%..%'` expression over the 015 normalised columns, with no
--     `position()` branch and no description match. A one-row, one-expression query lets the planner
--     take the trigram GIN for 3+ characters and fall back to a scan for 1-2, with no code branch.
--     The feed is a card list; description search is `search_catalog_v1`'s job.
-- A8. THE MISSING PLATFORM PARAMETER. `min_app_version` is keyed by platform and the signature is
--     not, so the gate is applied against every minimum present. See the behaviour-change block at
--     the top of this file: it is a conservative reading, it masks a feature when the two platform
--     floors differ, and the real fix is a `contracts.md` amendment adding a platform parameter.
--     Not invented here.
-- A9. `targeting_rules.percentage` IS honoured, bucketed on `md5(user_id)` so a user is stable
--     across calls with no stored assignment. The spec documents the key and no bucketing rule.
-- A10. `targeting_rules.city_codes` is IGNORED. The caller's city is not in the JWT and is not
--     derivable from it - one account shops in any area it likes - so honouring it would need a
--     parameter the contract does not have. Recorded as a gap, not as support for the key.
-- A11. Business dates resolve in the PRIMARY city's timezone from `cities.timezone`, via the
--     `cities_one_primary` unique index. `current_date` would be the server's timezone, which is
--     wrong for every evening hour in Cairo. One city at a time is constitution V.25. Implemented
--     once, in `private.earnings_window`, and separately in the two admin/dashboard functions that
--     need a single business date rather than a window.
-- A12. `get_flags_v1` returns FLAGS ONLY. `settings` is served by `get_setting_v1(p_key)`
--     (contracts.md 1.9). `settings` holds money constants and constitution I.1 and I.7 forbid the
--     app deriving anything from them, so shipping them here would invite exactly the client-side
--     fee calculation the constitution prohibits.
-- A13. `get_vendor_dashboard_v1` does NOT filter `vendors.is_active`, `is_approved` or `deleted_at`.
--     014 says so explicitly for vendor-owned rows: "Vendor-owned rows a vendor must also be able
--     to READ when inactive - to fix their own menu". A deactivated vendor must be able to log in
--     and see that it happened. This is the ONE place in this file that returns more than the RLS
--     policy would, and it is confined to the caller's own vendor ids.
-- A14. No admin bypass on the vendor dashboard or on either earnings function. An admin who is also
--     vendor staff sees their own; an admin who is not gets zero rows. Admin-wide money views are
--     `get_platform_float_v1` (019) and `get_admin_metrics_v1` (this file).
-- A15. No `support` role bypass anywhere, although `user_roles.role` includes 'support' and
--     data-model.md 13.1's matrix has no column for it. Inventing a support grant is not this
--     file's decision.
-- A16. `get_admin_metrics_v1` omits a city-wide live open-order count. `status not in (terminal)`
--     matches no index prefix and would be a scan of the whole orders table on a screen an operator
--     leaves open. BranchInbox and `get_available_orders_v1` own that number. It DOES report
--     "placed today and not yet terminal", which is bounded by the day's index range.
-- A17. The feed omits `cuisine_ids`, `latitude`/`longitude` and the delivery fee. Cuisines and
--     coordinates belong in the R2 snapshot, served by Cloudflare for free; a per-vendor cuisine
--     array is ~30 bytes x 40 rows on the second most-used screen in the app. Distance cannot be
--     computed here anyway: the contract gives this function no `p_lat`/`p_lng`.
-- A18. Both earnings functions clamp the range to 365 days and REPORT `range_clamped` in the
--     response, so a caller that asked for two years is told its window was cut rather than
--     silently handed a year of numbers. contracts.md 5 has no code for an over-long range. A
--     reversed range yields an empty report rather than an error, which is a legible answer to a
--     caller who passed the dates backwards. See `private.earnings_window`.
-- A19. `get_rider_earnings_v1` returns NO rider name while `get_vendor_earnings_v1` returns one. The
--     asymmetry is deliberate: `vendor_staff` is many-to-many so one person demonstrably may work at
--     two vendors and the app cannot otherwise label the two blocks, whereas there is no documented
--     case of one user holding two `riders` rows. If that case ever arises the payload becomes
--     ambiguous and `riders.user_id` needs a unique constraint - a schema question for a later
--     migration, not something to answer here with an unused column.
-- =============================================================================================

-- =============================================================================================
-- semver_gte - a real version comparison, because the spec's sample was inert
-- =============================================================================================
-- data-model.md 1's `get_flags_v1` sample reads `min_app_version->>p_app_version`, using a version
-- string as a JSON key. It is never present, coalesces to '', and the condition is always true, so
-- the documented version gate does nothing at all. A rollout floor that never fires is worse than
-- no floor: it is a guarantee that exists only in the documentation.
--
-- The regex guard before the int cast is load-bearing twice over. An unparseable MINIMUM must not
-- gate anything, or an admin typo switches off a feature for every user at once. An unparseable
-- CLIENT VERSION must gate, because a client this function cannot reason about does not get a
-- feature it may not understand. The CASE around each cast guarantees the cast is never evaluated
-- on junk - a bare `string_to_array(...)::int[]` in a CTE would raise rather than skip.
create or replace function public.semver_gte(p_have text, p_need text)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  with h as (
    select btrim(p_have) as s,
           case when btrim(p_have) ~ '^[0-9]+(\.[0-9]+){0,2}$'
                then string_to_array(btrim(p_have), '.')::int[]
                else null::int[]
           end as a
  ), n as (
    select btrim(p_need) as s,
           case when btrim(p_need) ~ '^[0-9]+(\.[0-9]+){0,2}$'
                then string_to_array(btrim(p_need), '.')::int[]
                else null::int[]
           end as a
  )
  select case
           when n.s is null or n.s = ''           then true
           when h.s is null or h.s = ''           then false
           when n.s !~ '^[0-9]+(\.[0-9]+){0,2}$' then true
           when h.s !~ '^[0-9]+(\.[0-9]+){0,2}$' then false
           -- Row comparison, not `::text >=` on the joined string: as text '1.10' < '1.9', as
           -- versions '1.10' > '1.9'. The trailing-element coalesce is why each side is padded to
           -- three integers rather than compared as arrays: array comparison treats a missing
           -- trailing element as NULL and NULL sorts LAST in ASC, which would make '1.4' compare
           -- GREATER than '1.4.0' and wrongly gate every 1.4.x client.
           else (coalesce(h.a[1], 0), coalesce(h.a[2], 0), coalesce(h.a[3], 0))
              >= (coalesce(n.a[1], 0), coalesce(n.a[2], 0), coalesce(n.a[3], 0))
         end
  from h, n
$$;

revoke execute on function public.semver_gte(text, text) from public, anon;

-- =============================================================================================
-- get_flags_v1
-- =============================================================================================
-- Signature fixed by data-model.md 1: get_flags_v1(p_app_role, p_app_version) -> (flag_key, value).
-- 16 seed keys, so the whole response is ~770 bytes and the whole table is read. No index would
-- help and none is wanted.
--
-- `is_active` is the 014 predicate on feature_flags, re-stated because SECURITY DEFINER bypasses it:
-- an inactive flag is a flag an admin switched off.
--
-- Returns flag_key and value ONLY. targeting_rules, description, updated_at and updated_by are
-- excluded - targeting_rules is the largest field in the table and the client has no use for the
-- rules once they have been applied. That is roughly 40% of the bytes for free.
create or replace function public.get_flags_v1(
  p_app_role    text default null,
  p_app_version text default null
)
returns table (flag_key text, value jsonb)
language sql
stable
security definer
set search_path = ''
as $$
  with caller as (
    select (select auth.uid()) as uid
  ),
  resolved as (
    select f.flag_key, f.value
    from public.feature_flags f, caller c
    where f.is_active
      -- roles. A null p_app_role cannot match a targeted flag, so an unidentified caller sees
      -- untargeted flags only.
      and (f.targeting_rules->'roles' is null
           or jsonb_typeof(f.targeting_rules->'roles') <> 'array'
           or (p_app_role is not null
               and exists (select 1
                             from jsonb_array_elements_text(f.targeting_rules->'roles') r
                             where r.value = p_app_role)))
      -- vendor_ids. Compared as TEXT on both sides: casting an operator-authored uuid straight to
      -- uuid would raise on a malformed entry, turning a bad flag definition into an app outage.
      and (f.targeting_rules->'vendor_ids' is null
           or exists (select 1
                       from jsonb_array_elements_text(f.targeting_rules->'vendor_ids') v
                       where v.value = any (select vi::text
                                             from private.vendor_ids_for(c.uid) vi)))
      -- min_app_version. A8: applied against every minimum present, because the contract has no
      -- platform parameter.
      and (
        f.targeting_rules->'min_app_version' is null
        or case jsonb_typeof(f.targeting_rules->'min_app_version')
             when 'string'
               then public.semver_gte(p_app_version, f.targeting_rules->>'min_app_version')
             when 'object'
               then not exists (select 1
                                  from jsonb_each_text(f.targeting_rules->'min_app_version') m
                                  where not public.semver_gte(p_app_version, m.value))
             else true
           end
      )
      -- percentage. Absent or unparseable means 100, i.e. everyone; the regex keeps a typo from
      -- raising. The bucket is md5(uid), deterministic without storing an assignment anywhere.
      and (
        case when f.targeting_rules->>'percentage' ~ '^[0-9]{1,3}$'
             then (f.targeting_rules->>'percentage')::int
             else 100 end >= 100
        or (('x' || substr(md5(coalesce(c.uid::text, 'anon')), 1, 8))::bit(32)::int
            & 2147483647) % 100
           < case when f.targeting_rules->>'percentage' ~ '^[0-9]{1,3}$'
                  then (f.targeting_rules->>'percentage')::int
                  else 100 end
      )
  )
  select r.flag_key, r.value
  from resolved r
  order by r.flag_key
$$;

grant  execute on function public.get_flags_v1(text, text) to authenticated;
revoke execute on function public.get_flags_v1(text, text) from public, anon;

-- =============================================================================================
-- get_vendor_feed_v1
-- =============================================================================================
-- Signature fixed by contracts.md 1.1:
--   get_vendor_feed_v1(p_area_id, p_vertical, p_open_only, p_query, p_offset, p_limit, p_sort)
--   -> vendors[] + cursor; cache-miss path only; max 40 per page.
--
-- Re-implements 014's `vendors_read` predicate verbatim - is_active AND is_approved AND
-- deleted_at is null - plus 015's `vendor_areas.is_active` area check, because SECURITY DEFINER
-- bypasses both. A customer must not be able to fetch a pending vendor's card by calling this
-- instead of the PostgREST route.
--
-- NO N+1. One page, one scan, `count(*) over ()` for the cursor in the same pass, then one
-- jsonb_agg over that same pass. Nothing re-queries per row.
--
-- SORT STABILITY, and it costs a duplicated key list. Offset pagination over a non-deterministic
-- order silently duplicates and drops rows across pages, and rating_avg ties constantly at launch
-- when most vendors have zero or one review. Every sort therefore ends with `v.id`, and the ORDER
-- BY is repeated inside `row_number() over (...)` because PostgreSQL applies window functions
-- BEFORE ORDER BY/LIMIT - a bare `row_number() over ()` would number rows in scan order and the
-- array would come back shuffled relative to the ranking. That ordering of operations is a
-- documented PostgreSQL rule, not a guess, and getting it wrong here produces a feed whose page 2
-- does not continue page 1.
--
-- KNOWN COST: the CASE-wrapped sort keys may not constant-fold to a bare column, so this probably
-- SORTS the ~150 filtered rows rather than walking `vendors_rating_avg` in order. At the launch
-- catalog in tasks.md T0.9 that is free. It is named here because it is the first thing that would
-- need four explicit branches if the catalog ever reaches five figures.
create or replace function public.get_vendor_feed_v1(
  p_area_id   uuid    default null,
  p_vertical  text    default null,
  p_open_only boolean default false,
  p_query     text    default null,
  p_offset    int     default 0,
  p_limit     int     default 12,
  p_sort      text    default 'rating'
)
returns table (payload jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q        text := public.normalize_text_v1(p_query);
  v_vertical text := nullif(btrim(coalesce(p_vertical, '')), '');
  v_sort     text := case when lower(btrim(coalesce(p_sort, '')))
                            in ('rating', 'name', 'prep_time', 'min_order')
                          then lower(btrim(p_sort)) else 'rating' end;
  v_lim      int  := greatest(1, least(coalesce(p_limit, 12), 40));
  v_off      int  := least(greatest(coalesce(p_offset, 0), 0), 2000);
begin
  return query
  with page as (
    select
      v.id, v.slug, v.name, v.name_ar, v.vertical_type, v.logo_path,
      v.rating_avg, v.rating_count, v.minimum_order_value, v.prep_time_minutes,
      -- One derived string instead of two booleans. is_open and is_busy are not two states, they
      -- are three (open / paused / closed), and a client switching on two flags will get one of
      -- them wrong. 'paused' is the vendor's own choice; 'closed' is simply not open.
      case when v.is_open then 'open'
           when v.is_busy then 'paused'
           else 'closed' end as availability,
      v.menu_version,
      count(*) over () as total,
      row_number() over (order by
        case when v_sort = 'name'      then v.name end,
        case when v_sort = 'prep_time' then v.prep_time_minutes end,
        case when v_sort = 'min_order' then v.minimum_order_value end,
        case when v_sort = 'rating'    then v.rating_avg end desc,
        v.id) as ord
    from public.vendors v
    where v.is_active and v.is_approved and v.deleted_at is null
      and (v_vertical is null or v.vertical_type = v_vertical)
      and (not coalesce(p_open_only, false) or v.is_open)
      -- EXISTS, not a join: one vendor serves many areas and a join would multiply the vendor row
      -- once per area served before the limit is applied. Same shape search_catalog_v1 uses.
      and (p_area_id is null or exists (
            select 1 from public.vendor_areas va
             where va.vendor_id = v.id and va.area_id = p_area_id and va.is_active))
      -- A7. One expression, both lengths: the planner takes the trigram GIN for 3+ characters and
      -- falls back to a scan for 1-2, with no branch here.
      and (v_q = ''
           or v.name_normalized like '%' || v_q || '%'
           or v.name_ar_normalized like '%' || v_q || '%')
    order by
      case when v_sort = 'name'      then v.name end,
      case when v_sort = 'prep_time' then v.prep_time_minutes end,
      case when v_sort = 'min_order' then v.minimum_order_value end,
      case when v_sort = 'rating'    then v.rating_avg end desc,
      v.id
    limit v_lim offset v_off
  )
  select jsonb_build_object(
    'items', coalesce(jsonb_agg(jsonb_build_object(
                 'id', p.id,
                 'slug', p.slug,
                 'name', p.name,
                 'name_ar', p.name_ar,
                 'vertical_type', p.vertical_type,
                 'logo_path', p.logo_path,
                 'rating_avg', p.rating_avg,
                 'rating_count', p.rating_count,
                 'minimum_order_value', p.minimum_order_value,
                 'prep_time_minutes', p.prep_time_minutes,
                 'availability', p.availability,
                 'menu_version', p.menu_version
               ) order by p.ord), '[]'::jsonb),
    'next_offset', case when coalesce(max(p.total), 0) > v_off + v_lim
                        then v_off + v_lim end,
    'has_more', coalesce(max(p.total), 0) > v_off + v_lim
  )
  from page p;
end $$;

grant  execute on function public.get_vendor_feed_v1(uuid, text, boolean, text, int, int, text)
  to authenticated;
revoke execute on function public.get_vendor_feed_v1(uuid, text, boolean, text, int, int, text)
  from public, anon;

-- =============================================================================================
-- get_vendor_dashboard_v1
-- =============================================================================================
-- Signature: get_vendor_dashboard_v1(p_vendor_id uuid default null) -> one payload row per vendor the
-- caller staffs. See A1b: this function comes from data-model.md 15.2 row 020 and is ABSENT from
-- contracts.md rather than contradicted by it; a contracts.md row is being added for it by the
-- maintainer. The parameter is the one invented part, and it is intersected with the JWT-derived
-- vendor set so it cannot widen access.
--
-- One row per vendor the caller staffs. A caller with no vendor_staff row gets zero rows, and zero
-- rows is the correct answer rather than an error - a signed-in customer who opens the vendor
-- dashboard has no vendors, and an error there is noise.
--
-- WHAT IT DOES NOT INCLUDE. No menu, no order list, no customer identity, no address.
-- `vendor.new_order` pushes to BranchInbox and `list_vendor_orders_v1` serves the inbox
-- (contracts.md 1.6); this is the summary above it. Everything it returns is a counter or a small
-- scalar, because this is the function free-tier-plan 4.2 identifies as costing 86 MB/day when
-- polled at 60 s.
--
-- `today` is NULL when the nightly rollup has not written the row yet. That is a real state, not an
-- error, and reporting it as 0 would tell a vendor they earned nothing today when in fact nothing
-- has been computed yet. The app shows "not settled yet" for null.
--
-- NO N+1, and the aggregate cannot multiply the vendor row: LEFT JOIN to sub_orders on vendor_id
-- with GROUP BY v.id. A correlated subquery per vendor would be an N+1 over the caller's vendors;
-- this is one join on an indexed column and one group.
create or replace function public.get_vendor_dashboard_v1(
  p_vendor_id uuid default null
)
returns table (payload jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz    text;
  v_today date;
begin
  -- A11. Business date in the operating city's timezone, never the server's.
  select c.timezone into v_tz from public.cities c where c.is_primary;
  v_tz := coalesce(v_tz, 'UTC');
  v_today := (now() at time zone v_tz)::date;

  return query
  select jsonb_build_object(
    'vendor', jsonb_build_object(
      'id', v.id, 'slug', v.slug, 'name', v.name, 'name_ar', v.name_ar,
      'logo_path', v.logo_path,
      'is_open', v.is_open, 'is_busy', v.is_busy,
      'is_approved', v.is_approved, 'is_active', v.is_active,
      'menu_version', v.menu_version,
      'rating_avg', v.rating_avg, 'rating_count', v.rating_count,
      'minimum_order_value', v.minimum_order_value,
      'prep_time_minutes', v.prep_time_minutes),
    'business_date', v_today,
    'generated_at', now(),
    'open_orders', jsonb_build_object(
      'total', count(so.id),
      'pending', count(so.id) filter (where so.status = 'pending'),
      'accepted', count(so.id) filter (where so.status = 'accepted'),
      'preparing', count(so.id) filter (where so.status = 'preparing'),
      'ready', count(so.id) filter (where so.status = 'ready')),
    'today', (select jsonb_build_object(
                 'orders_count', e.orders_count,
                 'cancelled_count', e.cancelled_count,
                 'gross_sales', e.gross_sales,
                 'discounts', e.discounts,
                 'delivery_fees', e.delivery_fees,
                 'commission', e.commission,
                 'adjustments', e.adjustments,
                 'net_payout', e.net_payout,
                 'cash_collected', e.cash_collected,
                 'wallet_collected', e.wallet_collected)
               from public.vendor_earnings_daily e
               where e.vendor_id = v.id and e.business_date = v_today and e.deleted_at is null),
    'items_needing_attention', jsonb_build_object(
      'unavailable', (select count(*) from public.menu_items mi
                       where mi.vendor_id = v.id and mi.deleted_at is null
                         and not mi.is_available),
      'out_of_stock', (select count(*) from public.menu_items mi
                        where mi.vendor_id = v.id and mi.deleted_at is null
                          and mi.is_available
                          and mi.stock_count is not null and mi.stock_count <= 0))
  )
  from public.vendors v
  left join public.sub_orders so
    on so.vendor_id = v.id
   and so.status in ('pending', 'accepted', 'preparing', 'ready')
  -- THE PREDICATE. Vendor id derived from the JWT, then narrowed by the client's request. Both
  -- halves must hold; supplying p_vendor_id alone can never widen this.
  where v.id in (select private.vendor_ids_for((select auth.uid())))
    and (p_vendor_id is null or v.id = p_vendor_id)
    -- A13: deliberately no is_active / is_approved / deleted_at filter, matching 014's vendor-side
    -- policy. A deactivated vendor must be able to log in and see that it happened.
  group by v.id, v_today;
end $$;

grant  execute on function public.get_vendor_dashboard_v1(uuid) to authenticated;
revoke execute on function public.get_vendor_dashboard_v1(uuid) from public, anon;

-- =============================================================================================
-- private.earnings_window - the one piece genuinely shared by the two earnings functions
-- =============================================================================================
-- Factored out because it is duplicated BUSINESS LOGIC, not duplicated boilerplate: which timezone a
-- business date is measured in, what the default window is, what a reversed window means, and where
-- the ceiling sits. That is fifteen lines of rules, and both earnings functions need all of it. Two
-- call sites, one implementation.
--
-- Deliberately NOT factored: the projections. `vendor_earnings_daily` and `rider_earnings_daily`
-- share no column names at all beyond `business_date`, so a shared projection helper would need a
-- discriminator and a null-padded column list - which is the exact shape that made the combined
-- version wide and hard to read. Two similar functions with different tables is the honest answer.
--
-- EXECUTE is revoked from authenticated, unlike `private.vendor_ids_for`. That revocation is safe
-- here precisely because 014 Finding 1 does not apply: no RLS policy calls this function, only the
-- two SECURITY DEFINER RPCs below, which run as the owner. The control that actually keeps it
-- unreachable is still the absence of schema USAGE on `private`.
--
-- OUT parameters are `win_*` prefixed because `to_date` is a PostgreSQL BUILT-IN function and an
-- output parameter of that name would shadow it inside this body.
create or replace function private.earnings_window(p_from date, p_to date)
returns table (win_from date, win_to date, win_clamped boolean)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tz text;
begin
  -- A11. The operating city's timezone, never the server's. `current_date` would be wrong for every
  -- evening hour in Cairo.
  select c.timezone into v_tz from public.cities c where c.is_primary;
  v_tz := coalesce(v_tz, 'UTC');

  win_to   := coalesce(p_to, (now() at time zone v_tz)::date);
  win_from := coalesce(p_from, win_to - 29);
  -- A reversed range yields an empty report rather than raising: a caller who passed the dates
  -- backwards deserves a legible answer, not an error.
  if win_from > win_to then
    win_from := win_to;
  end if;
  -- A18. Clamped, not rejected, and REPORTED as `range_clamped` in the response, so a caller that
  -- asked for two years is told its window was cut rather than silently handed a year of numbers.
  -- contracts.md 5 has no code for an over-long range and inventing one is not this file's job.
  win_clamped := win_from < win_to - 365;
  if win_clamped then
    win_from := win_to - 365;
  end if;
  return next;
end $$;

revoke execute on function private.earnings_window(date, date)
  from public, anon, authenticated, service_role;

-- =============================================================================================
-- get_vendor_earnings_v1
-- =============================================================================================
-- Signature fixed by contracts.md 1.6 line 127:
--   get_vendor_earnings_v1(p_from date, p_to date) -> daily rows + totals
--   source: vendor_earnings_daily
--
-- The combined `get_earnings_v1` that data-model.md 15.2 row 020 named and contracts.md did not has
-- been split into this function and `get_rider_earnings_v1`. contracts.md is authoritative on RPC
-- names, and it names these two - 1.6 for the vendor, 1.7 for the rider - so the contract wins and
-- row 020 is the document that is out of date.
--
-- NO p_owner_id AND NO p_owner_type, and that is the whole safety argument. There is no parameter a
-- client could aim at another account, so the function cannot be made to return a competitor's
-- revenue by any input. The account set is exactly `vendor_ids_for((select auth.uid()))`. Splitting
-- the function does not weaken this: it is per-function, so it survives the split intact.
--
-- `deleted_at is null` IS LOAD-BEARING TWICE OVER, and the second reason is the one that is easy to
-- miss. Semantically it keeps a reversed adjustment out of the report. Mechanically it matches the
-- partial predicate of `vendor_earnings_daily_live (vendor_id, business_date) where deleted_at is
-- null` EXACTLY, and a query predicate that does not imply the index's own predicate cannot use a
-- partial index at all. Drop the filter and the report gets slower AND wrong at the same time.
--
-- INDEX PREDICTION for this side: `vendor_id in (vendor_ids_for(uid))` resolves through
-- `vendor_staff`'s unique index `(user_id, vendor_id)`; `business_date between v_from and v_to`
-- becomes a range scan on the SECOND column of `vendor_earnings_daily_live`, once per vendor id.
-- A caller staffing one or two vendors gets one or two bounded index range scans. The `vendors` join
-- for the display name is a PK probe, and `settings` for the currency code is a PK lookup.
--
-- NO N+1: one scan of `vendor_earnings_daily`, then grouping and both aggregates in the same
-- statement.
create or replace function public.get_vendor_earnings_v1(
  p_from date default null,
  p_to   date default null
)
returns table (payload jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from   date;
  v_to     date;
  v_clamped boolean;
begin
  select w.win_from, w.win_to, w.win_clamped
    into v_from, v_to, v_clamped
  from private.earnings_window(p_from, p_to) w;

  return query
  with vend_rows as (
    -- Joined to vendors ONLY for the display name: `vendor_staff` is many-to-many, so one person may
    -- work at two vendors and the app has to label them (ADR 7). PK lookup. No filter on `vendors` -
    -- a soft-deleted vendor still has earnings rows somebody has to reconcile.
    select e.vendor_id as account_id,
           vn.name, vn.name_ar,
           e.business_date,
           e.orders_count, e.cancelled_count, e.gross_sales, e.discounts,
           e.delivery_fees, e.commission, e.adjustments, e.net_payout,
           e.cash_collected, e.wallet_collected
    from public.vendor_earnings_daily e
    join public.vendors vn on vn.id = e.vendor_id
    where e.deleted_at is null
      and e.business_date between v_from and v_to
      and e.vendor_id in (select private.vendor_ids_for((select auth.uid())))
  ), vend as (
    -- min() not any_value(): any_value() only exists from PostgreSQL 16 and this must not depend on
    -- the server version. It is equivalent here because name is constant per account_id.
    select r.account_id,
           min(r.name)    as name,
           min(r.name_ar) as name_ar,
           sum(r.orders_count)     as orders_count,
           sum(r.cancelled_count)  as cancelled_count,
           sum(r.gross_sales)      as gross_sales,
           sum(r.discounts)        as discounts,
           sum(r.delivery_fees)    as delivery_fees,
           sum(r.commission)       as commission,
           sum(r.adjustments)      as adjustments,
           sum(r.net_payout)       as net_payout,
           sum(r.cash_collected)   as cash_collected,
           sum(r.wallet_collected) as wallet_collected
    from vend_rows r
    group by r.account_id
  )
  select jsonb_build_object(
    'from', v_from,
    'to', v_to,
    'range_clamped', v_clamped,
    -- `#>> '{}'` unwraps a jsonb scalar; `::text` would return "EGP" with the quotes still on it.
    'currency', (select s.value #>> '{}' from public.settings s where s.key = 'currency'),
    'vendors', coalesce((
      select jsonb_agg(jsonb_build_object(
               'vendor_id', g.account_id,
               'name', g.name,
               'name_ar', g.name_ar,
               'daily', jsonb_build_object(
                 'orders_count',     g.orders_count,
                 'cancelled_count',  g.cancelled_count,
                 'gross_sales',      g.gross_sales,
                 'discounts',        g.discounts,
                 'delivery_fees',    g.delivery_fees,
                 'commission',       g.commission,
                 'adjustments',      g.adjustments,
                 'net_payout',       g.net_payout,
                 'cash_collected',   g.cash_collected,
                 'wallet_collected', g.wallet_collected),
               'rows', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'business_date', d.business_date,
                          'orders_count', d.orders_count,
                          'cancelled_count', d.cancelled_count,
                          'gross_sales', d.gross_sales,
                          'discounts', d.discounts,
                          'delivery_fees', d.delivery_fees,
                          'commission', d.commission,
                          'adjustments', d.adjustments,
                          'net_payout', d.net_payout,
                          'cash_collected', d.cash_collected,
                          'wallet_collected', d.wallet_collected)
                        order by d.business_date), '[]'::jsonb)
                 from vend_rows d
                 where d.account_id = g.account_id)
             ) order by g.name, g.account_id)
      from vend g
    ), '[]'::jsonb)
  );
end $$;

grant  execute on function public.get_vendor_earnings_v1(date, date) to authenticated;
revoke execute on function public.get_vendor_earnings_v1(date, date) from public, anon;

-- =============================================================================================
-- get_rider_earnings_v1
-- =============================================================================================
-- Signature fixed by contracts.md 1.7 line 147:
--   get_rider_earnings_v1(p_from date, p_to date) -> daily rows + totals
--
-- NO p_owner_id AND NO p_owner_type, same argument as the vendor side and the same guarantee. The
-- account set is exactly `private.rider_ids_for((select auth.uid()))`, which reads `riders.user_id`
-- for the caller and nothing else.
--
-- NO NAME IS RETURNED, and that is an asymmetry with the vendor side rather than an oversight. The
-- vendor side needs the name because `vendor_staff` is many-to-many and one person demonstrably may
-- work at two vendors (ADR 7), so the app cannot otherwise tell the two earnings blocks apart. There
-- is no such documented case for a rider - the rider app is acting as one rider - so the name would
-- be bytes for nothing. If a user ever holds two `riders` rows, this payload becomes ambiguous and
-- `riders.user_id` needs a unique constraint; that is a schema question for a later migration, not
-- something to answer with an unused column here.
--
-- `deleted_at is null` matches the partial predicate of `rider_earnings_daily_live (rider_id,
-- business_date) where deleted_at is null` exactly, for the same two reasons as the vendor side.
--
-- INDEX PREDICTION for this side: `rider_id in (rider_ids_for(uid))` is an EXISTS-style semi-join
-- over `riders.user_id`, served by `riders_user_id (user_id) where user_id is not null`;
-- `business_date between v_from and v_to` becomes a range scan on the SECOND column of
-- `rider_earnings_daily_live`, once per rider id. No join at all, so no second index is touched.
create or replace function public.get_rider_earnings_v1(
  p_from date default null,
  p_to   date default null
)
returns table (payload jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from   date;
  v_to     date;
  v_clamped boolean;
begin
  select w.win_from, w.win_to, w.win_clamped
    into v_from, v_to, v_clamped
  from private.earnings_window(p_from, p_to) w;

  return query
  with ride_rows as (
    select e.rider_id as account_id,
           e.business_date,
           e.deliveries, e.legs, e.online_minutes,
           e.base_fees, e.distance_fees, e.tips, e.bonuses,
           e.deductions, e.net_payout, e.cash_held, e.cash_remitted
    from public.rider_earnings_daily e
    where e.deleted_at is null
      and e.business_date between v_from and v_to
      and e.rider_id in (select private.rider_ids_for((select auth.uid())))
  ), ride as (
    select r.account_id,
           sum(r.deliveries)     as deliveries,
           sum(r.legs)           as legs,
           sum(r.online_minutes) as online_minutes,
           sum(r.base_fees)      as base_fees,
           sum(r.distance_fees)  as distance_fees,
           sum(r.tips)           as tips,
           sum(r.bonuses)        as bonuses,
           sum(r.deductions)     as deductions,
           sum(r.net_payout)     as net_payout,
           sum(r.cash_held)      as cash_held,
           sum(r.cash_remitted)  as cash_remitted
    from ride_rows r
    group by r.account_id
  )
  select jsonb_build_object(
    'from', v_from,
    'to', v_to,
    'range_clamped', v_clamped,
    'currency', (select s.value #>> '{}' from public.settings s where s.key = 'currency'),
    'riders', coalesce((
      select jsonb_agg(jsonb_build_object(
               'rider_id', h.account_id,
               'daily', jsonb_build_object(
                 'deliveries',     h.deliveries,
                 'legs',           h.legs,
                 'online_minutes', h.online_minutes,
                 'base_fees',      h.base_fees,
                 'distance_fees',  h.distance_fees,
                 'tips',           h.tips,
                 'bonuses',        h.bonuses,
                 'deductions',     h.deductions,
                 'net_payout',     h.net_payout,
                 'cash_held',      h.cash_held,
                 'cash_remitted',  h.cash_remitted),
               'rows', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'business_date', k.business_date,
                          'deliveries', k.deliveries,
                          'legs', k.legs,
                          'online_minutes', k.online_minutes,
                          'base_fees', k.base_fees,
                          'distance_fees', k.distance_fees,
                          'tips', k.tips,
                          'bonuses', k.bonuses,
                          'deductions', k.deductions,
                          'net_payout', k.net_payout,
                          'cash_held', k.cash_held,
                          'cash_remitted', k.cash_remitted)
                        order by k.business_date), '[]'::jsonb)
                 from ride_rows k
                 where k.account_id = h.account_id)
             ) order by h.account_id)
      from ride h
    ), '[]'::jsonb)
  );
end $$;

grant  execute on function public.get_rider_earnings_v1(date, date) to authenticated;
revoke execute on function public.get_rider_earnings_v1(date, date) from public, anon;

-- =============================================================================================
-- get_admin_metrics_v1
-- =============================================================================================
-- Signature fixed by contracts.md 1.9: get_admin_metrics_v1(p_date) -> funnel, orders, revenue by
-- line, cancellation, ETA accuracy.
--
-- GATED ON private.is_admin() IN THE BODY. Not because the caller is expected to be an admin -
-- because any authenticated customer can reach this endpoint through PostgREST, and `authenticated`
-- holds no grant on auth_daily_stats, search_daily_stats or platform_float, so without an explicit
-- gate SECURITY DEFINER would hand a customer the platform's entire revenue. Raises
-- NOT_AUTHORIZED (contracts.md 5) rather than returning an empty block.
--
-- REVENUE COMES FROM `platform_float`, NOT FROM AGGREGATING ORDERS. platform_float.business_date is
-- UNIQUE, so that is a single-row indexed lookup of twelve already-materialised money lines, and it
-- is the same number the settlement run reconciles against. Aggregating `orders` a second time
-- would produce a second answer to the same question, and two answers to a money question is the
-- failure mode constitution I.4 and I.10 exist to prevent. The order-derived sums ARE returned, but
-- under deliberately distinct names (`delivery_fees_from_orders` vs `delivery_fees_settled`) so a
-- support engineer can see the two disagree instead of the screen quietly picking one.
--
-- `float_variance` is surfaced, not filtered. constitution I.10 requires it to be zero or explained
-- in writing before the next settlement run, and a metrics screen that hid a non-zero variance would
-- defeat the only control standing behind that rule.
--
-- RATIOS ARE BASIS POINTS. A ratio is not money, but it is a number a dashboard multiplies and
-- formats, and integer bps cannot acquire a rounding artefact.
--
-- THE DAY BOUNDARY IS HALF-OPEN, [v_from, v_to). A BETWEEN over two timestamps would drop the last
-- second of the day, which is exactly the off-by-one that makes a daily revenue report quietly wrong
-- for a month before anyone checks.
create or replace function public.get_admin_metrics_v1(
  p_date date default null
)
returns table (payload jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz   text;
  v_date date;
  v_from timestamptz;
  v_to   timestamptz;

  v_placed        int;
  v_delivered     int;
  v_cancelled     int;
  v_open          int;
  v_rider_tips    int;
  v_delivery_fees int;
  v_promised      int;
  v_ontime        int;
  v_signups       bigint;

  v_search_clicks bigint;
  v_search_zero   bigint;
  v_search_total  bigint;
begin
  if not (select private.is_admin()) then
    raise exception 'NOT_AUTHORIZED: %', 'هذه الصفحة للمديرين فقط' using errcode = 'P0001';
  end if;

  select c.timezone into v_tz from public.cities c where c.is_primary;
  v_tz := coalesce(v_tz, 'UTC');
  v_date := coalesce(p_date, (now() at time zone v_tz)::date);

  v_from := v_date::timestamp at time zone v_tz;
  v_to   := (v_date + 1)::timestamp at time zone v_tz;

  -- Every count in the orders block comes out of ONE range scan on orders_placed (placed_at desc).
  select
    count(*)::int,
    count(*) filter (where o.status = 'delivered')::int,
    count(*) filter (where o.status in ('cancelled', 'partially_cancelled'))::int,
    count(*) filter (where o.status not in ('delivered', 'cancelled', 'partially_cancelled'))::int,
    coalesce(sum(o.rider_tip), 0)::int,
    coalesce(sum(o.delivery_fee), 0)::int,
    count(o.promised_delivery_at)::int,
    count(*) filter (where o.completed_at is not null
                       and o.promised_delivery_at is not null
                       and o.completed_at <= o.promised_delivery_at)::int
  into v_placed, v_delivered, v_cancelled, v_open,
       v_rider_tips, v_delivery_fees, v_promised, v_ontime
  from public.orders o
  where o.placed_at >= v_from and o.placed_at < v_to;

  select coalesce(sum(sd.clicks), 0),
         count(*) filter (where sd.zero_result),
         count(*)
  into v_search_clicks, v_search_zero, v_search_total
  from public.search_daily_stats sd
  where sd.business_date = v_date;

  select coalesce(sum(a.count), 0)
  into v_signups
  from public.auth_daily_stats a
  where a.business_date = v_date and a.event_name = 'signup';

  return query
  with eta as (
    -- Joined to orders on the day so the ORDERS index range drives the plan and
    -- order_eta_snapshots_order (order_id, computed_at desc) serves each lookup. Reading
    -- order_eta_snapshots alone would be a sequential scan with no usable date predicate on it.
    select (extract(epoch from (s.predicted_at - s.promised_at)) / 60) as err_min
    from public.order_eta_snapshots s
    join public.orders o on o.id = s.order_id
    where o.placed_at >= v_from and o.placed_at < v_to
  ), eta_agg as (
    select count(*)::int as samples,
           round(avg(err_min), 1) as avg_signed_min,
           round((percentile_cont(0.5) within group (order by err_min))::numeric, 1) as p50_min,
           round((percentile_cont(0.9) within group (order by err_min))::numeric, 1) as p90_min,
           round(avg(abs(err_min)), 1) as avg_abs_min
    from eta
  ), cancel_reasons as (
    -- A SECOND pass over the same orders range, not a third table. `group by cancellation_reason`
    -- matches no index and would be a scan on its own; here it reuses rows already narrowed to the
    -- day. At 2,000 orders/day that is a few hundred rows, and the alternative - no reason
    -- breakdown at all - is the number a support engineer actually asks for during a cancellation
    -- spike.
    select coalesce(jsonb_object_agg(r.reason, r.n), '{}'::jsonb) as by_reason
    from (
      select coalesce(o.cancellation_reason, 'unspecified') as reason, count(*)::int as n
      from public.orders o
      where o.placed_at >= v_from and o.placed_at < v_to
        and o.status in ('cancelled', 'partially_cancelled')
      group by 1
    ) r
  ), sub_agg as (
    select
      count(*)::int as total,
      count(*) filter (where so.status = 'cancelled')::int as cancelled,
      count(*) filter (where so.status = 'rejected')::int as rejected
    from public.sub_orders so
    join public.orders o on o.id = so.order_id
    where o.placed_at >= v_from and o.placed_at < v_to
  )
  select jsonb_build_object(
    'business_date', v_date,
    'timezone', v_tz,
    'generated_at', now(),

    'funnel', jsonb_build_object(
      'signups', v_signups,
      'logins', coalesce((select sum(a.count) from public.auth_daily_stats a
                           where a.business_date = v_date and a.event_name = 'login'), 0),
      'logins_failed', coalesce((select sum(a.count) from public.auth_daily_stats a
                                  where a.business_date = v_date
                                    and a.event_name = 'login_failed'), 0),
      'searches_with_clicks', v_search_clicks,
      'zero_result_searches', v_search_zero,
      'zero_result_rate_bps', case when v_search_total = 0 then 0
                                   else (v_search_zero * 10000 / v_search_total)::int end),

    'orders', jsonb_build_object(
      'placed', v_placed,
      'delivered', v_delivered,
      'cancelled', v_cancelled,
      -- Placed today and not yet terminal. Bounded by the day's index range, unlike a city-wide
      'open now' which matches no index prefix. See A16.
      'open', v_open,
      'completion_rate_bps', case when v_placed = 0 then 0
                                  else (v_delivered * 10000 / v_placed)::int end),

    'revenue', jsonb_build_object(
      'currency', (select s.value #>> '{}' from public.settings s where s.key = 'currency'),
      -- From orders, recomputed here on purpose, so it can be compared with the settled figure.
      'delivery_fees_from_orders', v_delivery_fees,
      'rider_tips', v_rider_tips,
      -- From platform_float: the settlement source of truth. One unique-index lookup.
      'delivery_fees_settled', (select pf.delivery_fees from public.platform_float pf
                                  where pf.business_date = v_date),
      'rider_cuts_settled', (select pf.rider_cuts from public.platform_float pf
                              where pf.business_date = v_date),
      'commissions_settled', (select pf.commissions from public.platform_float pf
                                where pf.business_date = v_date),
      'service_fees_settled', (select pf.service_fees from public.platform_float pf
                                 where pf.business_date = v_date),
      'adjustments_settled', (select pf.adjustments from public.platform_float pf
                                where pf.business_date = v_date),
      'vendor_payable', (select pf.vendor_payable from public.platform_float pf
                          where pf.business_date = v_date),
      'rider_payable', (select pf.rider_payable from public.platform_float pf
                         where pf.business_date = v_date),
      'external_cash_orders', (select pf.external_cash_orders from public.platform_float pf
                                 where pf.business_date = v_date),
      'external_wallet_orders', (select pf.external_wallet_orders from public.platform_float pf
                                   where pf.business_date = v_date),
      'cash_expected', (select pf.cash_expected from public.platform_float pf
                          where pf.business_date = v_date),
      'cash_remitted', (select pf.cash_remitted from public.platform_float pf
                         where pf.business_date = v_date),
      -- constitution I.10. Surfaced deliberately, never filtered to zero.
      'float_variance', (select pf.variance from public.platform_float pf
                          where pf.business_date = v_date)),

    'cancellation', jsonb_build_object(
      'orders_cancelled', v_cancelled,
      'order_rate_bps', case when v_placed = 0 then 0
                            else (v_cancelled * 10000 / v_placed)::int end,
      'sub_orders_total', (select s.total from sub_agg s),
      'sub_orders_cancelled', (select s.cancelled from sub_agg s),
      'sub_orders_rejected', (select s.rejected from sub_agg s),
      'by_reason', (select c.by_reason from cancel_reasons c)),

    'eta_accuracy', jsonb_build_object(
      -- promised vs actual at ORDER level. completed_at and promised_delivery_at are both
      -- unindexed, but the rows arrive from the orders_placed range scan, so this costs no extra
      -- index and no extra scan.
      'orders_with_promise', v_promised,
      'on_time_orders', v_ontime,
      'on_time_rate_bps', case when v_promised = 0 then 0
                               else (v_ontime * 10000 / v_promised)::int end,
      -- quoted vs predicted, from the snapshot table.
      'snapshots', (select e.samples from eta_agg e),
      'avg_signed_error_min', (select e.avg_signed_min from eta_agg e),
      'p50_signed_error_min', (select e.p50_min from eta_agg e),
      'p90_signed_error_min', (select e.p90_min from eta_agg e),
      'avg_abs_error_min', (select e.avg_abs_min from eta_agg e)),

    'vendors', jsonb_build_object(
      'active_approved', (select count(*) from public.vendors v
                           where v.is_active and v.is_approved and v.deleted_at is null),
      'open_now', (select count(*) from public.vendors v
                    where v.is_active and v.is_approved and v.deleted_at is null and v.is_open),
      'paused', (select count(*) from public.vendors v
                  where v.is_active and v.is_approved and v.deleted_at is null and v.is_busy),
      -- A vendor that is active but not approved is invisible to every customer. Counting
      -- `not is_active` here would have hidden the actual onboarding backlog.
      'pending_approval', (select count(*) from public.vendors v
                            where v.deleted_at is null and not v.is_approved),
      'soft_deleted', (select count(*) from public.vendors v
                        where v.deleted_at is not null)),

    'riders', jsonb_build_object(
      'active', (select count(*) from public.riders r where r.is_active),
      'online_now', (select count(*) from public.riders r where r.is_online and r.is_active),
      'verified_online', (select count(*) from public.riders r
                           where r.is_online and r.is_active and r.is_verified))
  );
end $$;

grant  execute on function public.get_admin_metrics_v1(date) to authenticated;
revoke execute on function public.get_admin_metrics_v1(date) from public, anon;

-- =============================================================================================
-- fail closed
-- =============================================================================================
-- What goes wrong silently in a migration like this one is not the syntax. It is the things that
-- compile, grant cleanly and are WRONG: a dropped admin gate, a dropped vendor_ids_for clause, a
-- lost search_path pin, a `select *` that quietly starts shipping a new column, a bare auth.uid(),
-- and a money column that turns up as a float. Every one of those is checked here rather than
-- trusted, on the same principle as 014 and 014a: a comment that claims a guarantee the code does
-- not provide is worse than no comment, because the next reviewer trusts it.
--
-- Each assertion is written so that it FAILS when the thing it checks is ABSENT. That is not
-- automatic - `if prosrc !~ 'private\.is_admin\(\)'` on a NULL prosrc evaluates to NULL, the IF is
-- not taken, and the assertion silently passes. Hence assertion 1 first proves all seven functions
-- exist, so no later assertion can be reasoning about a missing row.
--
-- Assertion 15 is specific to the earnings split: `get_earnings_v1` must not exist, not even as an
-- alias or a leftover overload. contracts.md 1.6 and 1.7 name two functions, row 020 named one, and
-- leaving the combined version behind would be dead code with a second way to reach the same money.
do $$
declare
  r          record;
  found_n    int;
  bare_auth  text;
  star_query text;
  fts        text;
  body       text;
begin
  -- 1. All seven exist, are STABLE or IMMUTABLE, and pin the search path to ''.
  --    `stable` is required, not cosmetic: an RPC PostgREST may evaluate twice in one statement must
  --    not observe the world changing underneath itself.
  --
  --    SECURITY DEFINER is required for the SIX public RPCs and NOT for `semver_gte`, which reads no
  --    table and touches no policy, so SECURITY DEFINER would buy it nothing. Asserting it anyway
  --    would fail this migration on correct code, and a guard that fails on correct code trains
  --    people to delete it. `private.earnings_window` is a plpgsql helper, not security definer,
  --    because it reaches no table that a policy governs.
  select count(*) into found_n
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('get_vendor_feed_v1', 'get_vendor_dashboard_v1',
                      'get_vendor_earnings_v1', 'get_rider_earnings_v1',
                      'get_admin_metrics_v1', 'get_flags_v1', 'semver_gte');

  if found_n <> 7 then
    raise exception 'FAIL CLOSED: expected 7 functions from 020, found %', found_n;
  end if;

  for r in
    select p.proname, p.prosecdef, p.provolatile, p.proconfig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('get_vendor_feed_v1', 'get_vendor_dashboard_v1',
                        'get_vendor_earnings_v1', 'get_rider_earnings_v1',
                        'get_admin_metrics_v1', 'get_flags_v1', 'semver_gte')
  loop
    if r.proname <> 'semver_gte' and r.prosecdef is not true then
      raise exception 'FAIL CLOSED: public.% is not SECURITY DEFINER', r.proname;
    end if;
    if r.provolatile not in ('s', 'i') then
      raise exception 'FAIL CLOSED: public.% is neither STABLE nor IMMUTABLE', r.proname;
    end if;
    -- PostgreSQL records an empty search_path as `search_path=` or `search_path=""` depending on
    -- version, so both spellings are accepted and anything else is a failure.
    if not exists (select 1 from unnest(coalesce(r.proconfig, '{}'::text[])) c
                    where c ~ '^search\_path=("")?$') then
      raise exception 'FAIL CLOSED: public.% does not pin search_path to empty', r.proname;
    end if;
  end loop;

  -- 2. No returned column is float, double precision or numeric - constitution I.3, money is
  --    integer piastres and never a float. Checked on the rendered return type rather than by
  --    unpacking proallargtypes/proargmodes: the rendered form is what the generated TypeScript
  --    signature comes from, so this asserts the thing a caller would actually receive.
  --    jsonb is allowed, because the envelope functions build their payload server-side; what is
  --    banned is a float COLUMN, which is how a float would enter a typed contract.
  select string_agg(format('%s -> %s', p.proname, pg_get_function_result(p.oid)), ', ')
    into fts
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('get_vendor_feed_v1', 'get_vendor_dashboard_v1',
                      'get_vendor_earnings_v1', 'get_rider_earnings_v1',
                      'get_admin_metrics_v1', 'get_flags_v1')
    and pg_get_function_result(p.oid) ~* '(numeric|double precision|real|float)';

  if fts is not null then
    raise exception 'FAIL CLOSED: a float or numeric column is exposed by %', fts;
  end if;

  -- 3. No bare auth.uid(). `(select auth.uid())` is stripped first; anything left is the bare form
  --    that migration 022 fails the build on inside a policy. Checking it here means the body never
  --    has to be re-read to prove it.
  select string_agg(p.proname, ', ') into bare_auth
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('get_vendor_feed_v1', 'get_vendor_dashboard_v1',
                      'get_vendor_earnings_v1', 'get_rider_earnings_v1',
                      'get_admin_metrics_v1', 'get_flags_v1')
    and regexp_replace(p.prosrc, '\(\s*select\s+auth\.uid\(\)\s*\)', '', 'gi')
        ~ 'auth\.uid\(\)';

  if bare_auth is not null then
    raise exception 'FAIL CLOSED: bare auth.uid() in %', bare_auth;
  end if;

  -- 4. No `select *` and no `select alias.*`. Enumerated columns only: a new column must be added
  --    to these functions deliberately or not at all, because its cost is multiplied by every poll
  --    of every user.
  select string_agg(p.proname, ', ') into star_query
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('get_vendor_feed_v1', 'get_vendor_dashboard_v1',
                      'get_vendor_earnings_v1', 'get_rider_earnings_v1',
                      'get_admin_metrics_v1', 'get_flags_v1')
    and p.prosrc ~* 'select\s+([a-z_][a-z0-9_]*\.)?\*';

  if star_query is not null then
    raise exception 'FAIL CLOSED: select * in %', star_query;
  end if;

  -- 5. The admin gate is INSIDE get_admin_metrics_v1, not around it. A customer can reach this
  --    endpoint through PostgREST, and SECURITY DEFINER with no table grant would otherwise hand
  --    out platform revenue.
  select p.prosrc into body
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_admin_metrics_v1';
  if body is null or body !~ 'private\.is_admin\(\)' or body !~ 'NOT_AUTHORIZED' then
    raise exception 'FAIL CLOSED: get_admin_metrics_v1 is no longer admin-gated inside the function';
  end if;

  -- 6. Ownership is still derived from the JWT, PER SIDE. This is the assertion that would have
  --    caught the 014 sub_order leak, written here for the same class of bug: a vendor's data
  --    reachable by naming somebody else's id. Three separate checks because the split means three
  --    separate functions can each lose their own gate independently - and a vendor earnings leak
  --    would be the worst of the three, since it is money.
  select p.prosrc into body
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_vendor_dashboard_v1';
  if body is null or body !~ 'vendor_ids_for' then
    raise exception
      'FAIL CLOSED: get_vendor_dashboard_v1 no longer scopes to the calling user''s own vendors';
  end if;

  select p.prosrc into body
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_vendor_earnings_v1';
  if body is null or body !~ 'vendor_ids_for' then
    raise exception
      'FAIL CLOSED: get_vendor_earnings_v1 no longer derives its vendors from the caller''s JWT';
  end if;

  -- The rider side must NOT be able to reach vendor earnings, and vice versa. Asserted in both
  -- directions, because a copy-paste between the two functions is the obvious way to break this.
  if body ~ 'rider_ids_for' or body ~ 'rider_earnings_daily' then
    raise exception
      'FAIL CLOSED: get_vendor_earnings_v1 can read rider earnings';
  end if;

  select p.prosrc into body
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_rider_earnings_v1';
  if body is null or body !~ 'rider_ids_for' then
    raise exception
      'FAIL CLOSED: get_rider_earnings_v1 no longer derives its riders from the caller''s JWT';
  end if;

  if body ~ 'vendor_ids_for' or body ~ 'vendor_earnings_daily' then
    raise exception
      'FAIL CLOSED: get_rider_earnings_v1 can read vendor earnings';
  end if;

-- Neither earnings function may accept an owner parameter. A parameter that names an account is
-- the one thing that could turn a JWT-derived scope into a forgeable one, so its absence is
-- asserted rather than assumed.
--
-- Written as "every declared INPUT parameter name is p_from or p_to" rather than as a count or a
-- rendered-text comparison. Both of those were tried against this database first and both failed on
-- correct code, which is worth recording so nobody reintroduces them:
--   * comparing pg_get_function_arguments text fails because that rendering includes `DEFAULT NULL`;
--   * comparing proargnames to a two-element array fails because proargnames spans OUT parameters
--     too. Verified on this project: pgbouncer.get_auth has proargnames {p_usename,username,password}
--     against proargmodes {i,t,t}. So `returns table (payload jsonb)` yields {p_from,p_to,payload}.
-- proargmodes is therefore the discriminator: only rows with mode 'i' are callable parameters, and
-- the OUT column is not one. Two single-argument unnest-with-ordinality calls joined on ordinality,
-- because `unnest(a, b)` in a lateral is not reliably supported and a guard must not depend on it.
-- A third input parameter could not also be named p_from or p_to, because those two are taken.
if exists (
  select 1
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join lateral unnest(coalesce(p.proargnames, '{}'::text[])) with ordinality as a(nm, ord)
    on true
  join lateral unnest(p.proargmodes) with ordinality as m(mode, ord)
    on m.ord = a.ord
  where n.nspname = 'public'
    and p.proname in ('get_vendor_earnings_v1', 'get_rider_earnings_v1')
    and m.mode = 'i'
    and lower(a.nm) not in ('p_from', 'p_to')
) then
  raise exception
    'FAIL CLOSED: an earnings function has an input parameter beyond (p_from, p_to)';
  end if;

  -- 7. The vendor feed still re-states 014's vendors_read predicate. SECURITY DEFINER bypasses
  --    is_active / is_approved / deleted_at, so an omission here is a customer browsing a pending
  --    vendor with no policy able to notice.
  select p.prosrc into body
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_vendor_feed_v1';
  if body is null or body !~* 'is_approved' or body !~* 'deleted_at is null'
     or body !~* 'vendor_areas' then
    raise exception
      'FAIL CLOSED: get_vendor_feed_v1 no longer re-states 014''s vendors_read visibility rule';
  end if;

-- 8. Both earnings functions keep their `deleted_at is null`. vendor_earnings_daily gained
  --    deleted_at in 005b; rider_earnings_daily shipped with it in 012. Each carries a partial
  --    "live" index whose predicate is `deleted_at is null`, and a query predicate that does not
  --    match the index's disables the index as well as leaking a reversed adjustment - so this one
  --    filter is doing correctness AND performance work, which is why it is counted rather than
  --    eyeballed. One per function now that they are split.
  select p.prosrc into body
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_vendor_earnings_v1';
  if (select count(*) from regexp_matches(body, 'deleted_at is null', 'gi')) < 1 then
    raise exception
      'FAIL CLOSED: get_vendor_earnings_v1 does not filter vendor_earnings_daily.deleted_at';
  end if;

  select p.prosrc into body
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_rider_earnings_v1';
  if (select count(*) from regexp_matches(body, 'deleted_at is null', 'gi')) < 1 then
    raise exception
      'FAIL CLOSED: get_rider_earnings_v1 does not filter rider_earnings_daily.deleted_at';
  end if;

  -- 9. semver_gte is IMMUTABLE, or every plan that inlines it and every dump/restore that depends
  --    on that plan becomes invalid. Checked on the definition AND on behaviour, because the
  --    behaviour is where the bug was: '1.10' beats '1.9' as a version and loses as text, and '1.4'
  --    must not be gated by a floor of '1.4.0'.
  if (select provolatile from pg_proc
      where oid = 'public.semver_gte(text,text)'::regprocedure) <> 'i' then
    raise exception 'FAIL CLOSED: semver_gte is not IMMUTABLE';
  end if;

  for r in
    select * from (values
      ('1.4.0',   '1.4.0',     true),
      ('1.4.1',   '1.4.0',     true),
      ('1.4',     '1.4.0',     true),   -- trailing zero implied
      ('1.10.0',  '1.9.0',     true),   -- numeric, not lexicographic
      ('1.9.0',   '1.10.0',    false),
      ('1.3.9',   '1.4.0',     false),
      ('2.0',     '1.999.999', true),
      (null,      '1.4.0',     false),  -- unknown client version does not get the flag
      ('1.4.0',   null,        true),   -- no floor gates nothing
      ('1.4.0',   '',          true),
      ('garbage', '1.4.0',     false),  -- unparseable client version is gated
      ('1.4.0',   'garbage',   true),   -- unparseable floor must not switch off a feature
      ('1.4.0-beta.1', '1.4.0', false)  -- a prerelease is not >= its own release
    ) as t(have, need, want)
  loop
    if public.semver_gte(r.have, r.need) is distinct from r.want then
      raise exception 'FAIL CLOSED: semver_gte(%, %) returned %, expected %',
        coalesce(r.have, 'null'), coalesce(r.need, 'null'),
        public.semver_gte(r.have, r.need), r.want;
    end if;
  end loop;

  -- 10. get_flags_v1 takes (text, text) and returns exactly (flag_key text, value jsonb). A third
  --     column is a silent egress regression on the one function every surface calls at launch, and
  --     it would change the generated TypeScript signature.
  --
  --     Asserted on `proallargtypes` - the oid array of every declared argument, inputs and the
  --     table output together - rather than on pg_get_function_result's text. An earlier draft
  --     compared that text to a literal 'TABLE(flag_key text, value jsonb)'; rendering is stable in
  --     practice but a guard that depends on exact server output formatting fails for reasons that
  --     have nothing to do with the code, and that is how guards get deleted. The oid array is
  --     exact, order-sensitive, and cannot drift with formatting. The array is FOUR elements, not
  --     three: p_app_role text, p_app_version text, then the two table outputs flag_key text and
  --     value jsonb. proallargtypes spans OUT columns as well as inputs - the same property that
  --     makes proargnames unsuitable for counting inputs in assertion 6, and it is verified on this
  --     project rather than assumed (pgbouncer.get_auth: 3 names, 3 argtypes, modes {i,t,t}).
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'get_flags_v1'
      and p.proallargtypes = array[
            'text'::regtype, 'text'::regtype, 'text'::regtype, 'jsonb'::regtype]::oid[]
  ) then
    raise exception
      'FAIL CLOSED: get_flags_v1 is not exactly (p_app_role text, p_app_version text) returning (flag_key text, value jsonb)';
  end if;

  -- 11. Privileges. anon gets nothing and PUBLIC gets nothing; authenticated gets EXECUTE on all
  --     six RPCs plus the version helper. has_function_privilege sees privilege inherited from
  --     PUBLIC too, so this is the effective check and not only the explicit grant.
  if has_function_privilege('anon', 'public.get_vendor_feed_v1(uuid,text,boolean,text,int,int,text)', 'execute')
     or has_function_privilege('anon', 'public.get_vendor_dashboard_v1(uuid)', 'execute')
     or has_function_privilege('anon', 'public.get_vendor_earnings_v1(date,date)', 'execute')
     or has_function_privilege('anon', 'public.get_rider_earnings_v1(date,date)', 'execute')
     or has_function_privilege('anon', 'public.get_admin_metrics_v1(date)', 'execute')
     or has_function_privilege('anon', 'public.get_flags_v1(text,text)', 'execute')
     or has_function_privilege('anon', 'public.semver_gte(text,text)', 'execute') then
    raise exception 'FAIL CLOSED: anon holds EXECUTE on a 020 read function';
  end if;

  if not has_function_privilege('authenticated', 'public.get_vendor_feed_v1(uuid,text,boolean,text,int,int,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.get_vendor_dashboard_v1(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.get_vendor_earnings_v1(date,date)', 'execute')
     or not has_function_privilege('authenticated', 'public.get_rider_earnings_v1(date,date)', 'execute')
     or not has_function_privilege('authenticated', 'public.get_admin_metrics_v1(date)', 'execute')
     or not has_function_privilege('authenticated', 'public.get_flags_v1(text,text)', 'execute') then
    raise exception 'FAIL CLOSED: authenticated cannot execute a 020 read function';
  end if;

  -- 11b. private.earnings_window must be unreachable by name AND unexecutable by a client. No
  --      RLS policy calls it, so unlike private.vendor_ids_for it does not need authenticated to
  --      hold EXECUTE - and it must not have it, because it is the window arithmetic both money
  --      functions depend on and has no business being a PostgREST endpoint.
  if has_function_privilege('anon', 'private.earnings_window(date,date)', 'execute')
     or has_function_privilege('authenticated', 'private.earnings_window(date,date)', 'execute')
     or has_function_privilege('service_role', 'private.earnings_window(date,date)', 'execute') then
    raise exception 'FAIL CLOSED: a client role can execute private.earnings_window';
  end if;

  -- 12. This migration adds no table privilege. 014's invariant - authenticated holds no
  --     INSERT/UPDATE/DELETE anywhere - is the reason an RPC is the only place a permission
  --     decision is written, and a read migration that quietly widened a grant would undo it.
  if exists (
    select 1 from information_schema.role_table_grants
    where grantee in ('anon', 'authenticated') and table_schema = 'public'
      and privilege_type <> 'SELECT'
  ) then
    raise exception 'FAIL CLOSED: a non-SELECT client grant exists';
  end if;

  -- 13. `private` is still shut. Every ownership predicate in this file runs through it, and the
  --     control that stops a client naming those helpers is the missing schema USAGE, not the
  --     EXECUTE revocation (014 Finding 1).
  if has_schema_privilege('authenticated', 'private', 'USAGE') then
    raise exception 'FAIL CLOSED: authenticated holds USAGE on private';
  end if;

  -- 14. The indexes these read paths depend on still carry the predicates the queries assume.
  --     Renaming or re-purposing one of these would turn an index scan into a sort, or worse a
  --     scan, with no error anywhere.
  --
  --     `indexdef` renders a partial predicate as `WHERE (deleted_at IS NULL)` in UPPER CASE, so
  --     the match is case-insensitive - a case-sensitive `like` fails on correct code, which is the
  --     failure mode 015 documents about a guard that duplicates the thing it guards.
  --
  --     The catalog indexes were created WITHOUT a name (`create index on menu_items (...)`), so
  --     that one is matched on shape rather than on a name this file would have to guess wrong.
  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public' and indexname = 'vendor_earnings_daily_live'
      and indexdef ilike '%deleted_at is null%'
  ) or not exists (
    select 1 from pg_indexes
    where schemaname = 'public' and indexname = 'rider_earnings_daily_live'
      and indexdef ilike '%deleted_at is null%'
  ) or not exists (
    select 1 from pg_indexes
    where schemaname = 'public' and indexname = 'sub_orders_vendor_open'
      and indexdef ilike '%(vendor_id, status)%'
  ) or not exists (
    select 1 from pg_indexes
    where schemaname = 'public' and indexname = 'orders_placed'
      and indexdef ilike '%(placed_at%'
  ) or not exists (
    select 1 from pg_indexes
    where schemaname = 'public' and tablename = 'menu_items'
      and indexdef ilike '%(vendor_id, is_available, display_order)%'
      and indexdef ilike '%deleted_at is null%'
  ) then
    raise exception
      'FAIL CLOSED: an index these read paths rely on is missing or its predicate changed';
  end if;

  -- 15. `get_earnings_v1` DOES NOT EXIST. contracts.md 1.6 and 1.7 name two functions; data-model.md
  --     15.2 row 020 named one combined function, and this migration follows contracts.md. If a
  --     combined `get_earnings_v1` is ever added - as an alias, an overload, or a leftover from an
  --     earlier apply of this file - it becomes a SECOND way to read the same money, with its own
  --     authorisation, its own response shape and no contract behind it. That is rule 10 dead code
  --     and it is a money surface, so it is asserted absent rather than merely not written.
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'get_earnings_v1'
  ) then
    raise exception
      'FAIL CLOSED: public.get_earnings_v1 exists; contracts.md 1.6 and 1.7 name two functions, not one';
  end if;
end $$;