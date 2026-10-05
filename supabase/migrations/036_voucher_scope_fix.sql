-- 036: an empty `applies_to_vendor_ids` must mean "every vendor", not "no vendor".
--
-- Symptom. Every voucher created with schema defaults was rejected on every cart:
--
--     quote_order_v1(...) with code SAVE10
--     -> VOUCHER_NOT_APPLICABLE, voucher_discount 0
--
-- Cause. `private.compute_quote` tested vendor scope with an array-overlap operator:
--
--     elsif v_voucher.applies_to_voucher_ids is not null
--        and not (v_voucher.applies_to_vendor_ids && v_vendor_ids) then
--       ... VOUCHER_NOT_APPLICABLE
--
-- The column is `uuid[] NOT NULL DEFAULT '{}'`, so `is null` is never true and that first
-- operand is dead code. An empty array overlaps nothing, `&&` is always false, `not false` is
-- true, and the rejection fires unconditionally. The scope check rejected 100% of vouchers
-- instead of only mis-scoped ones.
--
-- Why it survived. There is no voucher RPC (`count(*) from pg_proc where proname ilike
-- '%voucher%'` = 0 in public), so vouchers are reachable only by direct SQL today. No screen can
-- create one, so nothing user-visible had a chance to fail.
--
-- Blast radius. `private.compute_quote` is the ONLY function in the database that reads
-- `applies_to_vendor_ids`, verified across all 127 public + private functions. So this one
-- predicate is the entire behaviour of vendor scoping.
--
-- Semantics after the change, and why each case is safe:
--
--   []                    -> all vendors. New. Previously always rejected.
--   [a]                   -> only a. Unchanged: cardinality > 0, overlap test still runs.
--   [a,b]                 -> only a or b. Unchanged, same reason.
--   disabled entirely     -> is_active = false. Still short-circuits earlier, untouched.
--
-- "All vendors" must include vendors onboarded AFTER the voucher was created. That is the point
-- of this fix: enumerating ids at creation time would exclude every merchant signed later.
--
-- WHY THIS FILE PATCHES A STRING INSTEAD OF RESTATING THE FUNCTION
--
-- The first draft of this migration retyped all ~400 lines of `compute_quote` and dropped the
-- declaration of `v_discount`, so the file failed to compile with an error far from the real
-- cause. That is the same failure mode as the defect being fixed here: a large hand-maintained
-- copy of a function that quietly stops matching the function it replaces.
--
-- So the body is inherited from `pg_proc.prosrc` at run time and ONE substring is substituted.
-- Everything else is byte-for-byte whatever is installed, which is the only way a one-predicate
-- fix can be trusted not to have changed anything else. The substitution is asserted to match
-- EXACTLY ONCE, so if the guard's wording ever drifts this migration fails loudly instead of
-- silently producing a different pricing engine.
--
-- No data migration. Existing rows keep whatever scope they hold; a row that happens to be []
-- starts working, which is the intended repair and cannot alter an already-placed order because
-- placement re-derives the quote from the cart at that moment.

do $patch$
declare
  v_old constant text :=
    'elsif v_voucher.applies_to_vendor_ids is not null'
    || chr(10)
    || '       and not (v_voucher.applies_to_vendor_ids && v_vendor_ids) then';
  v_new constant text :=
    'elsif cardinality(v_voucher.applies_to_vendor_ids) > 0'
    || chr(10)
    || '       and not (v_voucher.applies_to_vendor_ids && v_vendor_ids) then';

  v_src      text;
  v_out      text;
  v_occurrences integer;
  v_guards   integer;
begin
  ----------------------------------------------------------------- precondition
  select p.prosrc into v_src
    from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private' and p.proname = 'compute_quote';

  if v_src is null then
    raise exception 'FAIL CLOSED: private.compute_quote does not exist.';
  end if;

  select count(*) into v_occurrences
    from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private' and p.proname = 'compute_quote'
     and p.prosrc like '%elsif v_voucher.applies_to_vendor_ids is not null%';

  if v_occurrences = 0 then
    raise exception
      'FAIL CLOSED: the vendor-scope guard is not in private.compute_quote. Either 036 already ran or the guard was rewritten. Read pg_proc.prosrc before changing anything.';
  end if;
  if v_occurrences > 1 then
    raise exception
      'FAIL CLOSED: the guard text appears % times, so a substitution would be ambiguous.', v_occurrences;
  end if;

  if position(v_old in v_src) = 0 then
    raise exception
      'FAIL CLOSED: exact guard text not found. Expected:%sActual:%s',
      v_old,
      substring(v_src from greatest(1, position('applies_to_vendor_ids' in v_src) - 40) for 170);
  end if;

  ----------------------------------------------------------------- substitute
  v_out := replace(v_src, v_old, v_new);

  if v_out = v_src then
    raise exception 'FAIL CLOSED: substitution produced no change.';
  end if;

  -- Exactly two lines differ, so a stray edit elsewhere would be visible here.
  if (length(v_out) - length(v_src)) <> (length(v_new) - length(v_old)) then
    raise exception
      'FAIL CLOSED: byte delta is %, expected %. The substitution touched more than the guard.',
      length(v_out) - length(v_src), length(v_new) - length(v_old);
  end if;

  ----------------------------------------------------------------- install
  execute format($fmt$
    create or replace function private.compute_quote(
      p_cart_id       uuid,
      p_address_id    uuid,
      p_voucher_code  text,
      p_rider_tip     integer,
      p_delivery_type text,
      p_grouping      text)
    returns jsonb
    language plpgsql
    stable
    security definer
    set search_path = ''
    as $fn$
%s
$fn$;
  $fmt$, v_out);

  ----------------------------------------------------------------- postconditions
  -- Text checks. NOT the evidence, only proof the substitution did what it claimed. The
  -- behavioural proof lives in `036_voucher_scope_fix_test.sql`, which calls the function and
  -- asserts on money, because a body can be textually perfect and semantically dead. That is
  -- exactly how `027` shipped green with a function that had never once succeeded.

  select p.prosrc into v_src
    from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private' and p.proname = 'compute_quote';

  -- THE FIX is present.
  if v_src not like '%cardinality(v_voucher.applies_to_vendor_ids) > 0%' then
    raise exception 'FAIL CLOSED: the empty-scope pass is missing after patching.';
  end if;

  -- The scope guard still EXISTS. Without this, "all vendors works" could be satisfied by
  -- deleting the check, which would hand every voucher to every shop.
  if v_src not like '%(v_voucher.applies_to_vendor_ids && v_vendor_ids)%' then
    raise exception
      'FAIL CLOSED: the overlap test is gone. An unscoped pass with no guard grants every voucher to every vendor.';
  end if;

  -- The dead predicate is gone, not merely bypassed.
  if v_src like '%applies_to_vendor_ids is not null%' then
    raise exception
      'FAIL CLOSED: `applies_to_vendor_ids is not null` survives. On a NOT NULL column it can never be false, so it is dead code that reads as a real guard.';
  end if;

  -- One function owns the scope decision, so there is no second unguarded path.
  select count(*) into v_guards
    from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public','private')
     and p.prosrc like '%VOUCHER_NOT_APPLICABLE%';

  if v_guards <> 1 then
    raise exception
      'FAIL CLOSED: expected exactly one function carrying VOUCHER_NOT_APPLICABLE, found %. A second path could apply a voucher with no scope check.', v_guards;
  end if;
end;
$patch$;

comment on function private.compute_quote(uuid,uuid,text,integer,text,text) is
  'Prices a cart. The only authority for what a customer is charged; place_order_v1 re-runs it inside the placing transaction. Since 036: an empty vouchers.applies_to_vendor_ids means ALL vendors, not none.';