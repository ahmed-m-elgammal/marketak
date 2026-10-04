-- 011b: 011a's four integrity triggers returned NULL, which silently discarded every row.
--
-- In a BEFORE trigger the return value is not cosmetic. Returning NEW proceeds with the operation;
-- returning NULL tells Postgres to SKIP it. Every one of 011a's functions ended in "return null",
-- which is the correct return for an AFTER statement-level trigger (where there is no row to
-- return) and completely wrong for a BEFORE row trigger.
--
-- The failure mode is the worst kind: no error, no warning, and a row that simply does not exist
-- afterwards. Caught by counting rows rather than trusting that an insert which raised no exception
-- had inserted anything:
--
--   wallet for a real vendor          no exception, count 0
--   ledger entry, platform, no owner  no exception, count 0
--   ledger entry, platform, with id   no exception - and it SHOULD have been rejected
--   two valid ledger entries          no exception, count 0
--
-- That last pair is the dangerous one. The integrity CHECK added in 011a never got a chance to
-- run, because the BEFORE trigger had already discarded the row, so a platform entry carrying an
-- account_id - exactly what the CHECK exists to forbid - was accepted and then thrown away.
--
-- The fix is one word per function. All four now RETURN NEW, and the null-owner early exit is
-- restructured into the condition rather than being an early return, because an early
-- "return null" would reintroduce the same bug on that path.
--
-- The correct pattern to copy lives in 006: sync_cart_item_vendor returns NEW. The rule to remember
-- is that a BEFORE row trigger returns NEW or NULL-to-skip, and an AFTER trigger returns NULL -
-- they are opposites, and mixing them fails silently rather than loudly.

create or replace function private.assert_wallet_owner()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.owner_id is not null and new.owner_type = 'vendor'
     and not exists (select 1 from public.vendors where id = new.owner_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: wallet owner' using errcode = '23503';
  end if;
  if new.owner_id is not null and new.owner_type = 'rider'
     and not exists (select 1 from public.riders where id = new.owner_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: wallet owner' using errcode = '23503';
  end if;
  return new;
end $$;

create or replace function private.assert_payout_account()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.payout_type = 'vendor'
     and not exists (select 1 from public.vendors where id = new.account_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: payout account' using errcode = '23503';
  end if;
  if new.payout_type = 'rider'
     and not exists (select 1 from public.riders where id = new.account_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: payout account' using errcode = '23503';
  end if;
  return new;
end $$;

create or replace function private.assert_ledger_account()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.account_type = 'vendor'
     and not exists (select 1 from public.vendors where id = new.account_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: ledger account' using errcode = '23503';
  end if;
  if new.account_type = 'rider'
     and not exists (select 1 from public.riders where id = new.account_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: ledger account' using errcode = '23503';
  end if;
  return new;
end $$;

create or replace function private.assert_commission_target()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.scope = 'vendor' and new.target_id is not null
     and not exists (select 1 from public.vendors where id = new.target_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: commission target' using errcode = '23503';
  end if;
  if new.scope = 'rider' and new.target_id is not null
     and not exists (select 1 from public.riders where id = new.target_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: commission target' using errcode = '23503';
  end if;
  return new;
end $$;