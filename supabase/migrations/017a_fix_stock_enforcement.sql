-- 017a: enforce stock on the purchase path, and un-break the refusal it needs
--
-- Two real defects, both in 017_rpc_core.sql, found by the 001-020 integrity
-- suite (specs/001-platform-foundation/001-020-integrity-notes.md section 7).
-- 017 is applied and must not be edited, so this is a forward fix in the same
-- spirit as 005a, 007a, 010a, 014a and 018a.
--
-- ---------------------------------------------------------------------------
-- DEFECT 1: stock_count was never consulted, so a sold-out item could be bought
-- ---------------------------------------------------------------------------
-- With stock_count = 0 on the only line in the cart:
--
--   quote_order_v1 on a SOLD-OUT item (stock_count=0)    QUOTE ISSUED
--   and placing that sold-out quote                       ORDER PLACED
--
-- The order completes. Three sources agree on the cause:
--
--   * 005_catalog.sql:64 declares stock_count with `null = unlimited`.
--   * The only other reference in any migration is 020_rpc_read.sql:528, which
--     READS it to hide sold-out items from browse. No function anywhere assigns
--     it, and none refuses on it.
--   * The fingerprint at 017:579-592 covers zone, fees, distance, vendor count,
--     subtotal, tip, discount, voucher and per line line_key, unit_price,
--     selected_size_id and selected_options. It contains neither is_available nor
--     stock_count.
--
-- That contradicts contracts.md:477 (`OUT_OF_STOCK | stock_count exhausted`) and
-- spec.md:519, which claims availability changes are caught via is_available and
-- stock_count in the fingerprint.
--
-- Fix: carry stock_count into the pricing CTEs and add an OUT_OF_STOCK
-- rejection, in the same place and the same shape as the six rejections already
-- there. Deliberately REFUSE ONLY. stock_count stays vendor-maintained and
-- `null = unlimited` keeps its meaning, which is what spec.md intends. This does
-- NOT decrement stock, so it does not stop two customers buying the last unit -
-- that is a product decision, not a bug fix, and is not taken here.
--
-- ---------------------------------------------------------------------------
-- DEFECT 2: the refusal that should have caught this was itself broken
-- ---------------------------------------------------------------------------
-- With is_available flipped to false between quote and place, the order is
-- correctly NOT placed - but the error surfaced is:
--
--   SQLSTATE 22P02  invalid input syntax for type json
--   Token "cart" is invalid.
--
-- not OUT_OF_STOCK or CART_NOT_PLACABLE. The cause is operator precedence in
-- place_order_v1:807-809:
--
--   perform private.err('CART_NOT_PLACABLE',
--     'cart has unpriceable lines: ' || v_q -> 'rejections'::text);
--
-- In PostgreSQL `||` binds TIGHTER than `->`, so this parses as
--
--   ('cart has unpriceable lines: ' || v_q) -> 'rejections'::text
--
-- The concatenation happens first and yields prose, then `->` coerces that prose
-- to json and fails. Reproduced standalone:
--
--   select pg_typeof('cart has unpriceable lines: '
--          || '{"rejections":[]}'::jsonb -> 'rejections'::text);
--   ERROR: 22P02 invalid input syntax for type json
--
-- So the guard raised nothing at all: private.err is never entered, because the
-- crash happens while evaluating its argument. Every rejection in the quote -
-- ITEM_UNAVAILABLE, ITEM_RETIRED, VENDOR_UNAVAILABLE, OUT_OF_STOCK and the rest
-- - has been reaching the client as an opaque Postgres error instead of a code
-- contracts.md defines. Fixing defect 1 without this would have converted a
-- clean refusal into the same crash, so both are required together.
--
-- Fix: parenthesise. 017_rpc_core.sql:435-437 already warns about exactly this
-- class of mistake for `::` versus `->>`; this is the same trap for `||`.
--
-- ===========================================================================
-- WARNING: the live application of this migration was botched, and corrected
-- by 017b_restore_checkout_functions.sql. Read that file before trusting this
-- one to describe the database.
--
-- This file was verified on disk and then a hand-typed copy of it was applied
-- instead, dropping large parts of both function bodies - including the whole
-- zone/fee assignment block and IDEMPOTENCY_KEY_TAKEN. The function bodies
-- below are correct and are what the database now contains, via 017b.
-- ===========================================================================



create or replace function private.compute_quote(
  p_cart_id       uuid,
  p_address_id    uuid,
  p_voucher_code  text,
  p_rider_tip     int,
  p_delivery_type text,
  p_grouping      text
)
returns jsonb
language plpgsql
volatile
set search_path to ''
as $$
declare
  v_user         uuid := auth.uid();
  v_zone         public.delivery_zones%rowtype;
  v_addr         public.addresses%rowtype;
  v_lines        jsonb;
  v_rejections   jsonb := '[]'::jsonb;
  v_vendor_ids   uuid[];
  v_vendor_cnt   int;
  v_subtotal     int := 0;
  v_discount     int := 0;
  v_base_fee     int;
  v_mult_bps     int;
  v_free_radius  numeric;
  v_per_km       int;
  v_max_distance numeric;
  v_distance     numeric := 0;
  v_delivery_fee int;
  v_service_fee  int := 0;
  v_service_on   boolean;
  v_service_amt  int;
  v_tip          int;
  v_total        int;
  v_max_vendors  int;
  v_vendor_sub   jsonb;
  v_ok           boolean := true;
  v_cur          char(3);
  v_fp           text;
  v_voucher      public.vouchers%rowtype;
  v_voucher_disc int := 0;
  v_n            int;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  if coalesce(p_rider_tip, 0) < 0 then
    perform private.err('TIP_INVALID', 'tip cannot be negative');
  end if;
  v_tip := coalesce(p_rider_tip, 0);

  if p_delivery_type is not null and p_delivery_type not in ('delivery','pickup') then
    perform private.err('DELIVERY_TYPE_INVALID', 'delivery type must be delivery or pickup');
  end if;
  if p_grouping is not null and p_grouping not in ('together','separate') then
    perform private.err('GROUPING_INVALID', 'grouping must be together or separate');
  end if;

  if not exists (select 1 from public.carts c
                  where c.id = p_cart_id and c.user_id = v_user and c.is_active) then
    perform private.err('CART_NOT_FOUND', 'no active cart with that id');
  end if;

  select * into v_addr from public.addresses a
   where a.id = p_address_id and a.user_id = v_user and a.deleted_at is null;
  if not found then
    perform private.err('ADDRESS_NOT_FOUND', 'address not found');
  end if;

  select count(*) into v_n from public.cart_items where cart_id = p_cart_id;
  if v_n = 0 then
    perform private.err('CART_EMPTY', 'cart has no items');
  end if;

  -- constitution 7: the entire fee falls out of this row. Nothing below is a
  -- literal, including the defaults, which come from settings.
  select * into v_zone from public.delivery_zones z
   where z.area_id = v_addr.area_id and z.is_active;
  if not found then
    perform private.err('NO_DELIVERY_ZONE', 'no active delivery zone covers this address');
  end if;
  v_base_fee     := v_zone.delivery_base_fee;
  v_free_radius  := v_zone.free_radius_km;
  v_per_km       := v_zone.per_km_fee;
  v_max_distance := v_zone.max_distance_km;
  v_max_vendors  := coalesce(v_zone.max_vendors_per_order,
                             private.setting_int('max_vendors_per_order', 3));
  v_cur          := v_zone.currency;

  -- Per-line pricing. Availability, retirement and range problems become
  -- rejections rather than exceptions, because spec 2.6 requires that one bad
  -- vendor never loses the whole basket.
  with src as (
    select ci.id as cart_item_id, ci.vendor_id, ci.menu_item_id, ci.quantity,
           ci.selected_options, ci.selected_size_id,
           mi.name, mi.name_ar, mi.pricing_mode, mi.base_price,
           mi.is_available, mi.stock_count, mi.deleted_at, mi.preparation_time_minutes,
           v.latitude as v_lat, v.longitude as v_lng,
           v.is_active as v_active, v.is_approved as v_approved,
           sz.name as size_name, sz.price as size_price,
           sz.is_available as size_available
      from public.cart_items ci
      join public.menu_items mi on mi.id = ci.menu_item_id
      join public.vendors v on v.id = ci.vendor_id
      left join public.menu_item_sizes sz
             on sz.id = ci.selected_size_id and sz.item_id = ci.menu_item_id
     where ci.cart_id = p_cart_id
  ),
  opts as (
    -- Count only elements that FAILED to resolve. Counting oc.id is null counts
    -- the zero rows a LEFT JOIN LATERAL emits for an empty array, which would
    -- reject every item that legitimately has no options and zero its money.
    select s.cart_item_id,
           coalesce(sum(oc.price_modifier), 0)::int as modifiers,
           count(*) filter (where e IS NOT NULL AND oc.id IS NULL) as unknown_choices
      from src s
      left join lateral jsonb_array_elements(
               case when jsonb_typeof(s.selected_options) = 'array'
                    then s.selected_options else '[]'::jsonb end) e on true
      left join public.option_choices oc
             on oc.id = private.try_uuid(e ->> 'choice_id')
     group by s.cart_item_id
  ),
  priced as (
    select s.cart_item_id::text as line_key,
           s.cart_item_id, s.vendor_id, s.menu_item_id, s.name, s.name_ar,
           s.quantity, s.selected_options, s.selected_size_id,
           s.size_name, s.size_price, s.preparation_time_minutes,
            s.deleted_at, s.is_available, s.stock_count, s.v_active, s.v_approved, s.size_available,
           s.pricing_mode, s.base_price,
           o.unknown_choices,
           case
             when s.pricing_mode = 'sized' then s.size_price + coalesce(o.modifiers, 0)
             else coalesce(s.base_price, 0) + coalesce(o.modifiers, 0)
           end as unit_price,
           public.haversine_km(v_addr.latitude, v_addr.longitude, s.v_lat, s.v_lng) as distance_km
      from src s join opts o on o.cart_item_id = s.cart_item_id
  ),
  flagged as (
    select p.*,
      case
        when p.deleted_at is not null                       then 'ITEM_RETIRED'
        when not p.v_active or not p.v_approved              then 'VENDOR_UNAVAILABLE'
        when not p.is_available                              then 'ITEM_UNAVAILABLE'
        -- 017a: stock was carried but never acted on. `null` still means unlimited,
        -- per 005_catalog.sql, so only an explicit zero or below is a refusal.
        when p.stock_count is not null and p.stock_count <= 0 then 'OUT_OF_STOCK'
        when p.pricing_mode = 'sized' and p.size_price is null then 'SIZE_REQUIRED'
        when p.pricing_mode = 'sized' and not coalesce(p.size_available, false)
                                                             then 'SIZE_UNAVAILABLE'
        when p.unknown_choices > 0                          then 'OPTION_UNAVAILABLE'
        when p.distance_km > v_max_distance                 then 'OUT_OF_RANGE'
        else null
      end as rejection_code
      from priced p
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'cart_item_id', f.cart_item_id,
             'vendor_id',    f.vendor_id,
             'menu_item_id', f.menu_item_id,
             'name',         f.name,
             'name_ar',      f.name_ar,
             'quantity',     f.quantity,
             'unit_price',   f.unit_price,
             'total_price',  f.unit_price * f.quantity,
             'selected_options', f.selected_options,
             'selected_size_id',    f.selected_size_id,
             'selected_size_name',  f.size_name,
             'selected_size_price', f.size_price,
             'prep_estimate_minutes', f.preparation_time_minutes,
             'distance_km',     round(f.distance_km::numeric, 3),
             'rejection_code',  f.rejection_code
           ) order by f.cart_item_id), '[]'::jsonb)
    into v_lines
  from flagged f;

  -- One actionable rejection per vendor rather than one per line.
  select coalesce(jsonb_agg(jsonb_build_object(
           'vendor_id',  e.vendor_id,
           'code',       e.code,
           'message_ar', e.message_ar) order by e.vendor_id), '[]'::jsonb)
    into v_rejections
  from (
    select distinct on (f->>'vendor_id')
           f->>'vendor_id' as vendor_id,
           f->>'rejection_code' as code,
           case f->>'rejection_code'
             when 'ITEM_RETIRED'       then 'هذا الصنف لم يعد متاحا'
             when 'VENDOR_UNAVAILABLE' then 'المحل غير متاح الطلب'
             when 'ITEM_UNAVAILABLE'   then 'هذا الصنف غير متاح'
             when 'OUT_OF_STOCK'        then 'نفدت كمية هذا الصنف'
             when 'SIZE_REQUIRED'      then 'اختر المقاس'
             when 'SIZE_UNAVAILABLE'   then 'المقاس غير متاح'
             when 'OPTION_UNAVAILABLE' then 'اختيارات غير متاحة'
             when 'OUT_OF_RANGE'       then 'المحل خارج نطاق التوصيل لمنطقتك'
             else 'غير متاح'
           end as message_ar
      from jsonb_array_elements(v_lines) f
     where f ->> 'rejection_code' is not null
     order by f ->> 'vendor_id', f ->> 'rejection_code'
  ) e;

  if jsonb_array_length(v_rejections) > 0 then
    v_ok := false;
  end if;

  -- Parenthesised: :: binds tighter than ->>, so `l ->> 'vendor_id'::uuid`
  -- casts the literal 'vendor_id' and raises 22P02. The text form of the same
  -- mistake fails silently as NULL instead, which is worse.
  select array_agg(distinct (l ->> 'vendor_id')::uuid),
         count(distinct (l ->> 'vendor_id')::uuid)
    into v_vendor_ids, v_vendor_cnt
  from jsonb_array_elements(v_lines) l;

  if v_vendor_cnt > v_max_vendors then
    v_rejections := v_rejections || jsonb_build_array(jsonb_build_object(
      'vendor_id', null, 'code', 'VENDOR_LIMIT_EXCEEDED',
      'message_ar', 'الحد الأقصى ' || v_max_vendors || ' محلات في الطلب الواحد'));
    v_ok := false;
  end if;

  -- Only priceable lines contribute money.
  select coalesce(sum((l ->> 'quantity')::int * (l ->> 'unit_price')::int), 0)::int
    into v_subtotal
  from jsonb_array_elements(v_lines) l
  where l ->> 'rejection_code' is null and l ->> 'unit_price' is not null;

  -- A1: the furthest vendor sets the fee.
  select coalesce(max((l ->> 'distance_km')::numeric), 0)
    into v_distance
  from jsonb_array_elements(v_lines) l
  where l ->> 'rejection_code' is null;

  select t.multiplier_bps into v_mult_bps
    from public.delivery_fee_tiers t
   where t.zone_id = v_zone.id and t.vendor_count = greatest(v_vendor_cnt, 1);
  if v_mult_bps is null then
    perform private.err('MISSING_FEE_TIER',
      'no delivery fee tier configured for ' || greatest(v_vendor_cnt, 1) || ' vendors');
  end if;

  -- spec 2.5 verbatim:
  --   round(base * multiplier / 10000) + max(0, km - free_radius) * per_km
  v_delivery_fee := round(v_base_fee::numeric * v_mult_bps / 10000)::int
                 + greatest(0, v_distance - v_free_radius)::int * v_per_km;

  v_service_on := private.setting_bool('service_fee_enabled', false);
  if v_service_on then
    v_service_amt := private.setting_int('service_fee_default', 0);
    v_service_fee := case private.setting_str('service_fee_type', 'fixed')
                       when 'percentage' then round(v_subtotal::numeric * v_service_amt / 10000)::int
                       else v_service_amt
                     end;
  end if;

  -- Voucher. Percentage, cap and minimum all come from the row (constitution 7).
  if p_voucher_code is not null and btrim(p_voucher_code) <> '' then
    select * into v_voucher from public.vouchers v where upper(v.code) = upper(btrim(p_voucher_code));
    if not found then
      v_rejections := v_rejections || jsonb_build_array(jsonb_build_object(
        'vendor_id', null, 'code', 'VOUCHER_UNKNOWN', 'message_ar', 'كود الخصم غير معروف'));
      v_ok := false;
    elsif not v_voucher.is_active
       or (v_voucher.valid_from  is not null and now() < v_voucher.valid_from)
       or (v_voucher.valid_until is not null and now() > v_voucher.valid_until) then
      v_rejections := v_rejections || jsonb_build_array(jsonb_build_object(
        'vendor_id', null, 'code', 'VOUCHER_EXPIRED', 'message_ar', 'انتهت صلاحية الكود'));
      v_ok := false;
    elsif v_voucher.usage_limit_total is not null
       and v_voucher.usage_count >= v_voucher.usage_limit_total then
      v_rejections := v_rejections || jsonb_build_array(jsonb_build_object(
        'vendor_id', null, 'code', 'VOUCHER_EXHAUSTED', 'message_ar', 'انتهى استخدام هذا الكود'));
      v_ok := false;
    elsif v_voucher.min_order_value is not null and v_subtotal < v_voucher.min_order_value then
      v_rejections := v_rejections || jsonb_build_array(jsonb_build_object(
        'vendor_id', null, 'code', 'VOUCHER_MINIMUM_NOT_MET',
        'message_ar', 'الطلب أقل من الحد المطلوب للكود'));
      v_ok := false;
    elsif v_voucher.first_order_only and exists (
           select 1 from public.orders o where o.user_id = v_user and o.status <> 'cancelled') then
      v_rejections := v_rejections || jsonb_build_array(jsonb_build_object(
        'vendor_id', null, 'code', 'VOUCHER_FIRST_ORDER_ONLY',
        'message_ar', 'الكود لأول طلب فقط'));
      v_ok := false;
    elsif v_voucher.applies_to_vendor_ids is not null
       and not (v_voucher.applies_to_vendor_ids && v_vendor_ids) then
      v_rejections := v_rejections || jsonb_build_array(jsonb_build_object(
        'vendor_id', null, 'code', 'VOUCHER_NOT_APPLICABLE',
        'message_ar', 'الكود لا ينطبق على هذه المحلات'));
      v_ok := false;
    else
      v_voucher_disc := case v_voucher.discount_type
        when 'percentage'    then round(v_subtotal::numeric * v_voucher.discount_value / 10000)::int
        when 'free_delivery' then v_delivery_fee
        else v_voucher.discount_value
      end;
      if v_voucher.max_discount_cap is not null then
        v_voucher_disc := least(v_voucher_disc, v_voucher.max_discount_cap);
      end if;
      v_voucher_disc := least(v_voucher_disc, v_subtotal);
    end if;
  end if;

  v_discount := v_voucher_disc;
  v_total := greatest(0, v_subtotal + v_delivery_fee + v_service_fee + v_tip - v_discount);

  -- Per-vendor reporting split. spec 2.5: the fee is ONE number for the order,
  -- allocated proportionally to each vendor's subtotal for reporting only,
  -- because rider pay and platform revenue are computed per order.
  select coalesce(jsonb_agg(jsonb_build_object(
           'vendor_id',    p.vendor_id,
           'subtotal',     p.subtotal,
           'delivery_fee_share', p.fee_share,
           'service_fee_share',  p.service_share,
           'discount_share',     p.disc_share,
           'commission_amount',  p.commission,
           'vendor_net_payout',  greatest(0, p.subtotal - p.commission),
           'prep_estimate_minutes', p.prep,
           'ready_estimate_minutes', greatest(0, p.prep - 2),
           'meets_minimum', true,
           'in_delivery_range', true) order by p.vendor_id), '[]'::jsonb)
    into v_vendor_sub
  from (
    select (l ->> 'vendor_id')::uuid as vendor_id,
           sum((l ->> 'quantity')::int * (l ->> 'unit_price')::int)::int as subtotal,
           max(coalesce((l ->> 'prep_estimate_minutes')::int, 0)) as prep,
           case when v_subtotal > 0 then round(sum((l ->> 'quantity')::int * (l ->> 'unit_price')::int)::numeric
                                              / v_subtotal * v_delivery_fee)::int else 0 end as fee_share,
           case when v_subtotal > 0 then round(sum((l ->> 'quantity')::int * (l ->> 'unit_price')::int)::numeric
                                              / v_subtotal * v_service_fee)::int else 0 end as service_share,
           case when v_subtotal > 0 then round(sum((l ->> 'quantity')::int * (l ->> 'unit_price')::int)::numeric
                                              / v_subtotal * v_discount)::int else 0 end as disc_share,
           -- constitution 9: vendor commission is OFF at launch. Read the rule
           -- rather than assume it, so switching it on is an update.
           case when private.setting_bool('vendor_commission_enabled', false)
                then (select coalesce(round(sum((l ->> 'quantity')::int * (l ->> 'unit_price')::int)
                              * cr.value / 10000), 0)::int
                        from public.commission_rules cr
                       where cr.scope = 'vendor' and cr.applies_to = 'subtotal'
                         and cr.is_active and cr.effective_from <= now()
                         and (cr.effective_until is null or cr.effective_until > now()))
                else 0 end as commission
      from jsonb_array_elements(v_lines) l
     where l ->> 'rejection_code' is null and l ->> 'unit_price' is not null
     group by l ->> 'vendor_id'
  ) p;

  -- The fingerprint. Every input that could change what the customer is charged
  -- goes in, sorted so it is order-independent. Anything omitted here is an
  -- input the customer consented to a price without ever seeing.
  v_fp := 'md5:' || md5(concat_ws('|',
    'v1',
    v_zone.id::text, v_base_fee::text, v_mult_bps::text,
    v_free_radius::text, v_per_km::text, v_distance::text,
    v_vendor_cnt::text, v_subtotal::text, v_delivery_fee::text,
    v_service_fee::text, v_tip::text, v_discount::text,
    coalesce(upper(btrim(coalesce(p_voucher_code, ''))), ''),
    coalesce(v_voucher.discount_type, ''), coalesce(v_voucher.discount_value::text, ''),
    coalesce(v_voucher.max_discount_cap::text, ''),
    coalesce((select string_agg(l ->> 'line_key' || '#' || coalesce(l ->> 'unit_price', '-')
             || '#' || coalesce(l ->> 'selected_size_id', '-')
             || '#' || coalesce((l ->> 'selected_options')::text, '[]'), ',' order by l ->> 'line_key')
             from jsonb_array_elements(v_lines) l), '')
  ));

  return jsonb_build_object(
    'ok', v_ok,
    'fingerprint', v_fp,
    'currency', v_cur,
    'vendor_ids', to_jsonb(v_vendor_ids),
    'rejections', v_rejections,
    'warnings', '[]'::jsonb,
    'lines', v_lines,
    'per_vendor', v_vendor_sub,
    'address_id', p_address_id,
    'voucher_code', nullif(btrim(coalesce(p_voucher_code, '')), ''),
    'rider_tip', v_tip,
    'delivery_type', coalesce(p_delivery_type, 'delivery'),
    'grouping', coalesce(p_grouping, 'together'),
    'fee_breakdown', jsonb_build_object(
      'delivery_base_fee',     v_base_fee,
      'vendor_count',          v_vendor_cnt,
      'vendor_multiplier_bps', v_mult_bps,
      'distance_km',           round(v_distance, 3),
      'free_radius_km',        v_free_radius,
      'per_km_fee',            v_per_km,
      'distance_charge',       greatest(0, v_distance - v_free_radius)::int * v_per_km,
      'delivery_fee',          v_delivery_fee,
      'service_fee',           v_service_fee,
      'service_fee_enabled',   v_service_on,
      'rider_tip',             v_tip,
      'currency',              v_cur),
    'totals', jsonb_build_object(
      'subtotal', v_subtotal, 'discount_amount', v_discount,
      'voucher_discount', v_voucher_disc,
      'voucher_code', nullif(btrim(coalesce(p_voucher_code, '')), ''),
      'delivery_fee', v_delivery_fee, 'service_fee', v_service_fee,
      'rider_tip', v_tip, 'total', v_total),
    'limits', jsonb_build_object(
      'vendor_count', v_vendor_cnt, 'max_vendors_per_order', v_max_vendors),
    'zone', jsonb_build_object(
      'id', v_zone.id, 'city_id', v_zone.city_id, 'area_id', v_zone.area_id,
      'delivery_base_fee', v_base_fee, 'free_radius_km', v_free_radius,
      'per_km_fee', v_per_km, 'max_vendors_per_order', v_max_vendors)
  );
end;
$$;

create or replace function public.place_order_v1(
  p_quote_id        uuid,
  p_payment_method  text,
  p_idempotency_key text,
  p_payment_channel text default null
)
returns table (
  order_id uuid, order_number text, sub_orders jsonb, totals jsonb
)
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v_user     uuid := auth.uid();
  v_cart     public.carts%rowtype;
  v_existing public.orders%rowtype;
  v_q        jsonb;
  v_old      jsonb;
  v_diff     jsonb;
  v_order    uuid := gen_random_uuid();
  v_number   text;
  v_channel  text;
  v_sub      uuid;
  v_seq      smallint := 0;
  v_line     jsonb;
  v_tot      jsonb;
  v_fb       jsonb;
  v_sub_sub  int;
  v_sub_fee  int;
  v_sub_svc  int;
  v_sub_disc int;
  v_sub_comm int;
  v_prep     int;
  v_subs     jsonb := '[]'::jsonb;
  v_pv       record;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    perform private.err('IDEMPOTENCY_KEY_REQUIRED', 'idempotency_key is required');
  end if;

  -- constitution 5, checked before anything else so a retry after a dropped
  -- response returns the original order rather than charging twice.
  select * into v_existing from public.orders o where o.idempotency_key = p_idempotency_key;
  if found then
    if v_existing.user_id <> v_user then
      perform private.err('IDEMPOTENCY_KEY_TAKEN', 'that idempotency key belongs to another order');
    end if;
    return query
    select v_existing.id, v_existing.order_number,
           coalesce((select jsonb_agg(jsonb_build_object(
                      'sub_order_id', so.id, 'vendor_id', so.vendor_id,
                      'status', so.status, 'subtotal', so.subtotal,
                      'sequence', so.sequence) order by so.sequence)
                     from public.sub_orders so where so.order_id = v_existing.id), '[]'::jsonb),
           jsonb_build_object(
             'subtotal', v_existing.subtotal, 'delivery_fee', v_existing.delivery_fee,
             'service_fee', v_existing.service_fee,
             'discount_amount', v_existing.discount_amount,
             'voucher_discount', v_existing.voucher_discount,
             'rider_tip', v_existing.rider_tip, 'total', v_existing.total,
             'currency', v_existing.currency);
    return;
  end if;

  -- constitution 18: the gate is enforced here, not only in the app.
  if not exists (select 1 from public.users u
                  where u.id = v_user and u.profile_completed_at is not null) then
    perform private.err('PROFILE_INCOMPLETE', 'complete your profile before ordering');
  end if;

  if p_payment_method not in ('cash','wallet') then
    perform private.err('PAYMENT_METHOD_INVALID', 'payment method must be cash or wallet');
  end if;

  -- A2
  if p_payment_method = 'cash' then
    v_channel := 'cod';
  else
    if p_payment_channel is null then
      perform private.err('PAYMENT_CHANNEL_REQUIRED',
        'wallet payments must state vodafone_cash or instapay');
    end if;
    if p_payment_channel not in ('vodafone_cash','instapay') then
      perform private.err('PAYMENT_CHANNEL_INVALID',
        'wallet channel must be vodafone_cash or instapay');
    end if;
    v_channel := p_payment_channel;
  end if;

  select * into v_cart from public.carts c
   where c.quote_id = p_quote_id and c.user_id = v_user;
  if not found then
    perform private.err('QUOTE_NOT_FOUND', 'no quote with that id');
  end if;
  if v_cart.quote_expires_at is null or now() > v_cart.quote_expires_at then
    perform private.err('QUOTE_EXPIRED', 'this quote expired, ask for a new price');
  end if;

  -- Re-price inside this transaction, from the same engine the quote used.
  -- This is the only authority: the client sent a quote_id, never a price.
  v_q := private.compute_quote(
    v_cart.id, v_cart.quote_address_id, v_cart.quote_voucher_code,
    v_cart.quote_rider_tip, v_cart.quote_delivery_type, v_cart.quote_grouping);

  if not (v_q ->> 'ok')::boolean then
    -- 017a: parenthesised. `||` binds tighter than `->` in PostgreSQL, so the
    -- unparenthesised form concatenated the prose FIRST and then handed it to
    -- `->` as json, raising 22P02 "invalid input syntax for type json" while
    -- evaluating this argument. private.err was never entered, so every
    -- rejection in the quote reached the client as an opaque Postgres error
    -- instead of a contracts.md code. See the header for the standalone repro.
    perform private.err('CART_NOT_PLACABLE',
      'cart has unpriceable lines: ' || (v_q -> 'rejections')::text);
  end if;

  -- constitution 2: abort rather than silently drift. The diff is itemised per
  -- contracts 1.5, which needs the old prices, which is why the whole quote is
  -- kept on the cart. A fingerprint alone can say that something moved but not
  -- what, and a "prices changed" sheet with no numbers in it is not consent.
  if v_q ->> 'fingerprint' is distinct from v_cart.quote_fingerprint then
    v_old := coalesce(v_cart.quote_snapshot, '{}'::jsonb);

    select coalesce(jsonb_agg(d.d order by d.d ->> 'sort_key'), '[]'::jsonb) into v_diff
    from (
      -- per-item price movement
      select jsonb_build_object(
               'type', 'ITEM_PRICE_CHANGED',
               'menu_item_id', n ->> 'menu_item_id',
               'item_name_ar', n ->> 'name_ar',
               'old_unit_price', (o #>> '{}')::int,
               'new_unit_price', (n ->> 'unit_price')::int,
               'sort_key', '0' || coalesce(n ->> 'menu_item_id', '')
             ) as d
        from jsonb_array_elements(coalesce(v_q -> 'lines', '[]'::jsonb)) n
        left join lateral (
          select x -> 'unit_price' as o from jsonb_array_elements(coalesce(v_old -> 'lines', '[]'::jsonb)) x
           where x ->> 'menu_item_id' = n ->> 'menu_item_id'
        ) prev on true
       where (prev.o ->> 'unit_price') is distinct from (n ->> 'unit_price')
      union all
      -- items that vanished from the cart entirely
      select jsonb_build_object(
               'type', 'ITEM_REMOVED',
               'menu_item_id', x ->> 'menu_item_id',
               'item_name_ar', x ->> 'name_ar',
               'old_unit_price', (x ->> 'unit_price')::int,
               'sort_key', '1' || coalesce(x ->> 'menu_item_id', '')
             )
        from jsonb_array_elements(coalesce(v_old -> 'lines', '[]'::jsonb)) x
       where not exists (select 1 from jsonb_array_elements(coalesce(v_q -> 'lines', '[]'::jsonb)) n
                          where n ->> 'menu_item_id' = x ->> 'menu_item_id')
      union all
      -- the delivery fee itself, which moves with vendor count and distance
      select jsonb_build_object(
               'type', 'DELIVERY_FEE_CHANGED',
               'old_delivery_fee', coalesce((v_old -> 'totals' ->> 'delivery_fee')::int, 0),
               'new_delivery_fee', (v_q -> 'totals' ->> 'delivery_fee')::int,
               'reason_ar', 'تغير عدد المطاعم في الطلب',
               'sort_key', '2')
       where coalesce((v_old -> 'totals' ->> 'delivery_fee')::int, -1)
             is distinct from (v_q -> 'totals' ->> 'delivery_fee')::int
      union all
      -- a voucher that stopped applying
      select jsonb_build_object(
               'type', 'VOUCHER_EXPIRED',
               'voucher_code', v_old -> 'totals' ->> 'voucher_code',
               'message_ar', 'انتهت صلاحية الكود',
               'sort_key', '3')
       where (v_old -> 'totals' ->> 'voucher_discount')::int is distinct from
             (v_q -> 'totals' ->> 'voucher_discount')::int
    ) d;

    perform private.err('PRICE_CHANGED',
      'prices changed: ' || jsonb_build_object(
        'code', 'PRICE_CHANGED', 'message_ar', 'تغيرت الأسعار',
        'diff', v_diff,
        'old_total', v_old -> 'totals',
        'new_total', v_q -> 'totals',
        'new_fee_breakdown', v_q -> 'fee_breakdown')::text);
  end if;

  v_tot := v_q -> 'totals';
  v_fb  := v_q -> 'fee_breakdown';
  v_number := private.new_order_number();

  insert into public.orders (
    id, order_number, user_id, status, subtotal,
    delivery_base_fee, delivery_multiplier_bps, distance_km, delivery_fee, service_fee,
    discount_amount, voucher_code, voucher_discount, rider_tip,
    rider_pay_total, platform_revenue, total, currency,
    price_fingerprint, pricing_version, payment_method, payment_channel, payment_status,
    delivery_type, delivery_grouping, vendor_limit_applied, address_id, address_snapshot,
    delivery_latitude, delivery_longitude, area_id, is_contactless, access_note,
    vendor_count, item_count, placed_at, idempotency_key)
  values (
    v_order, v_number, v_user, 'pending', (v_tot ->> 'subtotal')::int,
    (v_fb ->> 'delivery_base_fee')::int, (v_fb ->> 'vendor_multiplier_bps')::int,
    (v_fb ->> 'distance_km')::numeric, (v_tot ->> 'delivery_fee')::int, (v_tot ->> 'service_fee')::int,
    (v_tot ->> 'discount_amount')::int, v_tot ->> 'voucher_code', (v_tot ->> 'voucher_discount')::int,
    (v_tot ->> 'rider_tip')::int,
    0, 0, (v_tot ->> 'total')::int, v_q ->> 'currency',
    v_q ->> 'fingerprint', 1, p_payment_method, v_channel, 'unpaid',
    v_q ->> 'delivery_type', v_q ->> 'grouping',
    (v_q -> 'limits' ->> 'max_vendors_per_order')::smallint,
    v_cart.quote_address_id,
    (select jsonb_build_object('address_id', a.id, 'label', a.label, 'area_name', a.area_name,
                               'building', a.building, 'floor', a.floor, 'apartment', a.apartment,
                               'landmark', a.landmark, 'delivery_instructions', a.delivery_instructions,
                               'latitude', a.latitude, 'longitude', a.longitude,
                               'geohash_prefix', a.geohash_prefix)
       from public.addresses a where a.id = v_cart.quote_address_id),
    (select a.latitude from public.addresses a where a.id = v_cart.quote_address_id),
    (select a.longitude from public.addresses a where a.id = v_cart.quote_address_id),
    (select a.area_id from public.addresses a where a.id = v_cart.quote_address_id),
    false, null,
    (v_q -> 'limits' ->> 'vendor_count')::int,
    (select coalesce(sum((l ->> 'quantity')::int), 0)
       from jsonb_array_elements(v_q -> 'lines') l),
    now(), p_idempotency_key);

  -- II.11: one sub_order per vendor, never a nullable vendor_id on the order.
  for v_pv in
    select * from jsonb_to_recordset(v_q -> 'per_vendor')
      as p(vendor_id uuid, subtotal int, delivery_fee_share int, service_fee_share int,
           discount_share int, commission_amount int, vendor_net_payout int,
           prep_estimate_minutes int)
    order by vendor_id
  loop
    v_sub := gen_random_uuid();
    v_seq := v_seq + 1;
    insert into public.sub_orders (
      id, order_id, vendor_id, sequence, status, subtotal,
      delivery_fee_share, service_fee_share, discount_share,
      commission_amount, platform_fee_amount, vendor_net_payout,
      settlement_status)
    values (
      v_sub, v_order, v_pv.vendor_id, v_seq, 'pending', v_pv.subtotal,
      v_pv.delivery_fee_share, v_pv.service_fee_share, v_pv.discount_share,
      v_pv.commission_amount, 0, v_pv.vendor_net_payout,
      'payable');

    v_subs := v_subs || jsonb_build_array(jsonb_build_object(
      'sub_order_id', v_sub, 'vendor_id', v_pv.vendor_id, 'sequence', v_seq,
      'subtotal', v_pv.subtotal, 'delivery_fee_share', v_pv.delivery_fee_share,
      'discount_share', v_pv.discount_share, 'commission_amount', v_pv.commission_amount,
      'vendor_net_payout', v_pv.vendor_net_payout, 'status', 'pending'));

    -- II.12 and II.14: every field copied, never re-read from the catalog later.
    for v_line in
      select l from jsonb_array_elements(v_q -> 'lines') l
       where l ->> 'vendor_id' = v_pv.vendor_id::text
         and l ->> 'rejection_code' is null
    loop
      insert into public.order_items (
        sub_order_id, menu_item_id, item_name, item_name_ar, image_path,
        quantity, unit_price, total_price, selected_options,
        selected_size_id, selected_size_name, selected_size_price,
        special_instructions, item_status)
      values (
        v_sub, (v_line ->> 'menu_item_id')::uuid,
        v_line ->> 'name', v_line ->> 'name_ar',
        (select mi.image_path from public.menu_items mi where mi.id = (v_line ->> 'menu_item_id')::uuid),
        (v_line ->> 'quantity')::int, (v_line ->> 'unit_price')::int,
        (v_line ->> 'total_price')::int,
        coalesce(v_line -> 'selected_options', '[]'::jsonb),
        (v_line ->> 'selected_size_id')::uuid,
        v_line ->> 'selected_size_name', (v_line ->> 'selected_size_price')::int,
        (select ci.special_instructions from public.cart_items ci
          where ci.id = (v_line ->> 'cart_item_id')::uuid),
        'confirmed');
    end loop;
  end loop;

  -- The cart is spent. carts_one_active is a unique partial index on
  -- user_id where is_active, so the next cart needs this one released.
  update public.carts c
     set is_active = false,
         quote_id = null, quote_fingerprint = null, quote_expires_at = null,
         quote_address_id = null, quote_voucher_code = null, quote_rider_tip = null,
         quote_delivery_type = null, quote_grouping = null, quote_snapshot = null
   where c.id = v_cart.id and c.user_id = v_user;

  -- II.16
  -- events carries no actor column; the actor lives in the payload, which is
  -- what 016 does too.
  insert into public.events (type, aggregate_type, aggregate_id, payload)
  values ('order.placed', 'order', v_order,
          jsonb_build_object('order_id', v_order, 'user_id', v_user,
                             'vendor_ids', v_q -> 'vendor_ids',
                             'total', (v_tot ->> 'total')::int,
                             'currency', v_q ->> 'currency'));

  return query select v_order, v_number, v_subs, v_tot;
end;
$$;

