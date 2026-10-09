-- 029: cart write RPCs.
--
-- The cart is the input to quoting and the database is the authority on it. Until this migration
-- the cart was unwritable by any client: `authenticated` holds SELECT on `carts` and `cart_items`
-- and nothing else, and no function in the database inserted into either table. Every existing
-- write to `carts` was an UPDATE by `quote_order_v1` (parking a quote) or `place_order_v1`
-- (releasing it), and `cart_items` had zero writers at all.
--
-- ## What this migration adds
--
--   1. `public.upsert_cart_item_v1`  - add a line, or bump the quantity of an identical one
--   2. `public.remove_cart_item_v1`  - drop a line
--   3. `EXECUTE` grants for both, and the revoke that must accompany them
--   4. a correction to `cart_items_line_identity` - see the next section
--
-- ## The line-identity index had to change, and that is the substantive part of this migration
--
-- The existing index was:
--
--   CREATE UNIQUE INDEX cart_items_line_identity
--     ON public.cart_items USING btree (cart_id, menu_item_id, md5((selected_options)::text));
--
-- `selected_size_id` is NOT in that key. So the same menu item, with the same options, in two
-- DIFFERENT sizes produced the same key and collided with 23505 - "Medium" and "Large" of one pizza
-- could not both be in a cart. There was no workaround inside the function: the md5 is computed from
-- `selected_options`, which carries no size, so nothing the RPC writes can separate the two lines
-- unless the index itself changes.
--
-- It is rebuilt as:
--
--   (cart_id, menu_item_id, md5(selected_options::text), coalesce(selected_size_id, nil_uuid))
--
-- Two details are load-bearing:
--
--   * `coalesce(selected_size_id, '00000000-...')` because a UNIQUE index treats NULLs as distinct.
--     A bare `selected_size_id` column would let the same fixed-priced item with the same options be
--     inserted twice - the very duplicate the index exists to prevent.
--   * The nil uuid is not a real primary key, so it cannot collide with a size row.
--
-- This does NOT touch pricing. `private.compute_quote` builds its fingerprint from
-- `cart_item_id`, `unit_price`, `selected_size_id` and `selected_options::text` independently of any
-- index; changing uniqueness semantics changes which rows may coexist, never what a row costs.
--
-- Replaying this against a populated database needs the drop and create done with care - see the
-- note at the bottom of the file.
--
-- ## Why the function validates at write time at all
--
-- Because the database validates almost nothing here, and the gaps are on the money path:
--
--   * `trg_cart_item_orderable` is DEFERRABLE INITIALLY DEFERRED, so a menu item that is unavailable
--     or soft-deleted makes the insert fail AT COMMIT, not at the statement. The client would get an
--     opaque abort instead of `ITEM_UNAVAILABLE`.
--   * No constraint ties `menu_items.pricing_mode` to `cart_items.selected_size_id`, and the FK
--     permits a size belonging to a completely different item.
--   * `selected_options` is checked only as "is a jsonb array". Element shape is unvalidated, and
--     `private.compute_quote` reads only `e ->> 'choice_id'` - it never checks that the choice
--     belongs to an option attached to THIS item, so any option_choices row from anywhere in the
--     catalogue would price in.
--   * `item_options.min_selections` / `max_selections` are not enforced anywhere, so a required
--     option group could be silently empty and the line would price low.
--
-- Error codes reuse `private.compute_quote`'s vocabulary wherever the meaning is the same, so the
-- client's code->copy map is one map: ITEM_RETIRED, ITEM_UNAVAILABLE, SIZE_REQUIRED,
-- SIZE_UNAVAILABLE, OPTION_UNAVAILABLE.
--
-- ## What this deliberately does NOT do
--
--   * Stock is not checked. `compute_quote` owns that, and it owns it deliberately:
--     `when p.stock_count is not null and p.stock_count <= 0 then 'OUT_OF_STOCK'`. Duplicating it
--     here would create two authorities that can disagree.
--   * Vendor `is_active` / `is_approved` and delivery range are quote-time (VENDOR_UNAVAILABLE,
--     OUT_OF_RANGE).
--   * `max_vendors_per_order` is a quote-time limit.
--   * `vendor_id` is never set by the caller. `trg_cart_items_sync_vendor` overwrites it from
--     `menu_items.vendor_id` on every insert and update; the function reads the same column and
--     passes it through only to satisfy NOT NULL. A client-supplied vendor is discarded either way.
--
-- ## Index rebuild on a populated table
--
-- `DROP INDEX` / `CREATE UNIQUE INDEX` holds an ACCESS EXCLUSIVE lock for the build. Safe here
-- because `cart_items` holds 2 rows. Replayed against a populated database this must be built
-- `CONCURRENTLY` outside the migration wrapper, and the drop must follow the create rather than
-- precede it - creating the new index first and dropping the old one second leaves a window in
-- which both exist, which is strictly better than a window in which neither does.

-- ---------------------------------------------------------------------------
-- 1. line identity: add the size, with a nil-uuid sentinel for "no size"
-- ---------------------------------------------------------------------------
drop index if exists public.cart_items_line_identity;

create unique index cart_items_line_identity
  on public.cart_items using btree (
    cart_id,
    menu_item_id,
    md5((selected_options)::text),
    coalesce(selected_size_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

-- ---------------------------------------------------------------------------
-- 2. add, or bump the quantity of, one cart line
-- ---------------------------------------------------------------------------
create or replace function public.upsert_cart_item_v1(
  p_menu_item_id         uuid,
  p_selected_options     jsonb    default '[]'::jsonb,
  p_selected_size_id     uuid     default null,
  p_quantity             integer  default 1,
  p_special_instructions text     default null
)
returns table (
  cart_item_id uuid,
  cart_id      uuid,
  quantity     integer,
  unit_price   integer,
  is_new       boolean
)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_user          uuid := (select auth.uid());
  v_cart_id       uuid;
  v_existing_id   uuid;
  v_existing_qty  integer;
  v_result_qty    integer;
  v_result_id     uuid;
  v_vendor_id     uuid;
  v_pricing_mode  text;
  v_base_price    integer;
  v_is_available  boolean;
  v_item_deleted  boolean;
  v_size_name     text;
  v_size_price    integer;
  v_size_ok       boolean;
  v_modifiers     integer;
  v_unit          integer;
  v_bad_choices   integer;
  v_bad_group     record;
begin
  -- Gate first, so every other branch is unreachable without a session.
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  if p_menu_item_id is null then
    perform private.err('ITEM_REQUIRED', 'a menu item must be named');
  end if;

  if p_quantity is null or p_quantity < 1 or p_quantity > 99 then
    perform private.err('INVALID_QUANTITY', 'quantity must be between 1 and 99');
  end if;

  if p_selected_options is null or jsonb_typeof(p_selected_options) <> 'array' then
    perform private.err('INVALID_OPTIONS', 'selected_options must be a json array');
  end if;

  -- Item must exist, be sellable, and not be soft-deleted. Done here rather than left to the
  -- deferred constraint trigger, so the caller gets a code they can act on instead of an
  -- abort at COMMIT.
  select mi.vendor_id, mi.pricing_mode, mi.base_price, mi.is_available, (mi.deleted_at is not null)
    into v_vendor_id, v_pricing_mode, v_base_price, v_is_available, v_item_deleted
    from public.menu_items mi
   where mi.id = p_menu_item_id;

  if not found then
    perform private.err('ITEM_RETIRED', 'this item is no longer sold');
  end if;

  if v_item_deleted then
    perform private.err('ITEM_RETIRED', 'this item is no longer sold');
  end if;

  if not v_is_available then
    perform private.err('ITEM_UNAVAILABLE', 'this item is unavailable');
  end if;

  -- A size must belong to THIS item. The FK alone permits any size row in the catalogue, and the
  -- LEFT JOIN in compute_quote (`on sz.id = ci.selected_size_id and sz.item_id = ci.menu_item_id`)
  -- turns a cross-item size into a silent SIZE_REQUIRED at quote time, which reads as a bug.
  if v_pricing_mode = 'sized' then
    if p_selected_size_id is null then
      perform private.err('SIZE_REQUIRED', 'choose a size');
    end if;

    select sz.name, sz.price, sz.is_available
      into v_size_name, v_size_price, v_size_ok
      from public.menu_item_sizes sz
     where sz.id = p_selected_size_id
       and sz.item_id = p_menu_item_id;

    if not found then
      perform private.err('SIZE_UNAVAILABLE', 'that size does not belong to this item');
    end if;

    if not coalesce(v_size_ok, false) then
      perform private.err('SIZE_UNAVAILABLE', 'that size is unavailable');
    end if;
  else
    -- A size on a fixed-priced item cannot affect the price, so storing one would be a value the
    -- client cannot see the effect of. Refuse rather than silently ignore it.
    if p_selected_size_id is not null then
      perform private.err('SIZE_NOT_APPLICABLE', 'this item is not priced by size');
    end if;
  end if;

  -- Every choice must exist, be live, and belong to an option attached to THIS item. compute_quote
  -- checks none of this: it reads only `e ->> 'choice_id'` and joins `option_choices` with no
  -- predicate on the parent item, so a choice from anywhere in the catalogue would price in.
  with picks as (
    select (e.value ->> 'choice_id') as cid,
           (e.value ? 'choice_id')     as has_key
      from jsonb_array_elements(p_selected_options) as e(value)
  ),
  resolved as (
    select p.cid,
           p.has_key,
           oc.id as choice_id,
           io.id as option_id
      from picks p
      left join public.option_choices oc on oc.id = private.try_uuid(p.cid)
      left join public.item_options io on io.id = oc.option_id
  )
  select count(*) into v_bad_choices
    from resolved r
   where not r.has_key
      or r.cid is null
      or r.choice_id is null
      or r.option_id is null
      or exists (select 1 from public.option_choices oc
                  where oc.id = r.choice_id
                    and (oc.deleted_at is not null or not oc.is_available))
      or exists (select 1 from public.item_options io
                  where io.id = r.option_id
                    and (io.item_id is distinct from p_menu_item_id
                      or io.deleted_at is not null
                      or not io.is_available));

  if v_bad_choices > 0 then
    perform private.err('OPTION_UNAVAILABLE', 'a chosen option is not available for this item');
  end if;

  -- Money from the choices that survived. `price_modifier` may be negative.
  select coalesce(sum(oc.price_modifier), 0)
    into v_modifiers
    from jsonb_array_elements(p_selected_options) as e(value)
    join public.option_choices oc
      on oc.id = private.try_uuid(e.value ->> 'choice_id')
   where oc.deleted_at is null
     and oc.is_available;

  -- min_selections / max_selections per option group, including groups the caller sent nothing
  -- for. A required group that is simply absent is the case a "count what was sent" check misses.
  with chosen as (
    select io.id as option_id, count(*) as n
      from jsonb_array_elements(p_selected_options) as e(value)
      join public.option_choices oc
        on oc.id = private.try_uuid(e.value ->> 'choice_id')
      join public.item_options io
        on io.id = oc.option_id
     where io.item_id = p_menu_item_id
       and io.deleted_at is null
     group by io.id
  ),
  bounds as (
    select io.id, io.min_selections, io.max_selections, coalesce(c.n, 0) as n
      from public.item_options io
      left join chosen c on c.option_id = io.id
     where io.item_id = p_menu_item_id
       and io.deleted_at is null
       and (io.min_selections > 0 or io.max_selections is not null)
  )
  select id, min_selections, max_selections, n
    into v_bad_group
    from bounds
   where n < min_selections
      or (max_selections is not null and n > max_selections)
   limit 1;

  if found then
    perform private.err(
      'OPTION_SELECTION_INVALID',
      format('option %s: %s choices, needs %s to %s',
             v_bad_group.id, v_bad_group.n,
             v_bad_group.min_selections,
             coalesce(v_bad_group.max_selections::text, 'no limit')));
  end if;

  v_unit :=
      case
        when v_pricing_mode = 'sized' then coalesce(v_size_price, 0)
        else coalesce(v_base_price, 0)
      end
    + v_modifiers;

  -- One active cart per user, enforced by the partial unique index `carts_one_active`. Reuse the
  -- caller's if there is one; otherwise insert and, if a concurrent request won the race, take
  -- theirs. Letting the index referee the race is cheaper and more correct than a lock.
  select c.id into v_cart_id
    from public.carts c
   where c.user_id = v_user
     and c.is_active
   order by c.created_at desc
   limit 1;

  if v_cart_id is null then
    begin
      insert into public.carts (user_id)
      values (v_user)
      returning id into v_cart_id;
    exception when unique_violation then
      select c.id into v_cart_id
        from public.carts c
       where c.user_id = v_user and c.is_active
       limit 1;

      if v_cart_id is null then
        raise;
      end if;
    end;
  end if;

  -- Same item, same options, same size is ONE line with a bumped quantity. The identity matches
  -- the rebuilt index exactly, coalesce sentinel included, so the SELECT below and the UNIQUE
  -- index can never disagree about what "identical" means.
  select ci.id, ci.quantity
    into v_existing_id, v_existing_qty
    from public.cart_items ci
   where ci.cart_id = v_cart_id
     and ci.menu_item_id = p_menu_item_id
     and md5(ci.selected_options::text) = md5(p_selected_options::text)
     and coalesce(ci.selected_size_id, '00000000-0000-0000-0000-000000000000'::uuid)
       = coalesce(p_selected_size_id, '00000000-0000-0000-0000-000000000000'::uuid)
   limit 1;

  if v_existing_id is not null then
    -- Cap at 99 rather than erroring: the caller asked for a quantity and gets the quantity that
    -- exists, which is the number the UI must show. `cart_items_quantity_check` bounds it 1..99.
    v_result_qty := least(99, coalesce(v_existing_qty, 0) + p_quantity);

    update public.cart_items ci
       set quantity           = v_result_qty,
           cached_price       = v_unit,
           cached_at          = now(),
           selected_size_name = v_size_name,
           selected_size_price = v_size_price,
           special_instructions = coalesce(p_special_instructions, ci.special_instructions)
     where ci.id = v_existing_id;

    v_result_id := v_existing_id;
    is_new := false;
  else
    insert into public.cart_items (
      cart_id, vendor_id, menu_item_id, quantity, selected_options,
      selected_size_id, selected_size_name, selected_size_price,
      cached_price, cached_at, special_instructions
    )
    values (
      v_cart_id, v_vendor_id, p_menu_item_id, p_quantity, p_selected_options,
      p_selected_size_id, v_size_name, v_size_price,
      v_unit, now(), p_special_instructions
    )
    returning id into v_result_id;

    v_result_qty := p_quantity;
    is_new := true;
  end if;

  return query
  select v_result_id, v_cart_id, v_result_qty, v_unit, is_new;
end;
$$;

-- `display_snapshot` is deliberately left NULL. Its shape is not derivable from the catalog and
-- inventing one here would be a guess baked into a contract. Nothing reads it - `compute_quote`
-- touches neither it nor `cached_price` - so the absence costs nothing and documenting that costs
-- nothing.

-- ---------------------------------------------------------------------------
-- 3. drop one cart line
-- ---------------------------------------------------------------------------
-- Hard delete, not a soft one: `cart_items` has no `deleted_at` column, so there is no soft option
-- to choose. The row is transient - it exists to be quoted out of - and `place_order_v1` copies
-- what it needs into `order_items` and leaves the line behind orphaned by an inactive cart either
-- way.
create or replace function public.remove_cart_item_v1(
  p_cart_item_id uuid
)
returns table (
  cart_id        uuid,
  remaining      integer
)
language plpgsql
security definer
set search_path to '' as $$
declare
  v_user   uuid := (select auth.uid());
  v_cart_id uuid;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  if p_cart_item_id is null then
    perform private.err('CART_ITEM_REQUIRED', 'a cart item must be named');
  end if;

  -- Ownership is resolved through the cart, never from a client-supplied user_id. The subquery is
  -- what stops one shopper emptying another's basket.
  delete from public.cart_items ci
   where ci.id = p_cart_item_id
     and ci.cart_id in (
           select c.id from public.carts c
            where c.user_id = v_user
              and c.is_active
         )
   returning ci.cart_id into v_cart_id;

  if not found then
    perform private.err('CART_ITEM_NOT_FOUND', 'no such line in your active cart');
  end if;

  select count(*) into remaining
    from public.cart_items ci
   where ci.cart_id = v_cart_id;

  cart_id := v_cart_id;
  return query select v_cart_id, remaining;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. grants
-- ---------------------------------------------------------------------------
-- Functions are executable by PUBLIC by default. `anon` must hold nothing at all, and
-- `authenticated` must hold exactly these two - so the default is revoked explicitly before the
-- intended grant is made. Ordering matters: revoking after granting would undo the grant.
revoke all on function public.upsert_cart_item_v1(uuid, jsonb, uuid, integer, text) from public, anon;
revoke all on function public.remove_cart_item_v1(uuid) from public, anon;

grant execute on function public.upsert_cart_item_v1(uuid, jsonb, uuid, integer, text) to authenticated;
grant execute on function public.remove_cart_item_v1(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. compile probe
-- ---------------------------------------------------------------------------
-- Repo rule: every migration touching a plpgsql function ends with a call to it, because Postgres
-- validates a function body lazily and a migration that applied cleanly can still ship a function
-- that cannot run. A migration session carries no JWT, so `auth.uid()` is null and the expected
-- outcome is AUTH_REQUIRED - which proves the body parsed, ran, and reached its own gate.
do $$
begin
  perform * from public.upsert_cart_item_v1(
    gen_random_uuid(), '[]'::jsonb, null, 1, null
  );
  raise exception 'PROBE FAILED: upsert_cart_item_v1 ran without a session and did not raise AUTH_REQUIRED';
exception
  when others then
    if sqlerrm not like 'AUTH_REQUIRED%' then
      raise exception 'PROBE FAILED for upsert_cart_item_v1: %', sqlerrm;
    end if;
end $$;

do $$
begin
  perform * from public.remove_cart_item_v1(gen_random_uuid());
  raise exception 'PROBE FAILED: remove_cart_item_v1 ran without a session and did not raise AUTH_REQUIRED';
exception
  when others then
    if sqlerrm not like 'AUTH_REQUIRED%' then
      raise exception 'PROBE FAILED for remove_cart_item_v1: %', sqlerrm;
    end if;
end $$;
