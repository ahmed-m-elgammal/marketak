-- 011a: enforce referential integrity on the polymorphic columns, and fix a vacuous CHECK in 009.
--
-- Open question 3.14, resolved with option (a): a trigger per table. A foreign key cannot express
-- "this uuid names a row in vendors OR in riders, depending on a sibling column", so the four
-- polymorphic columns carried NO referential integrity at all. The database would accept a wallet for
-- a vendor who does not exist, or a ledger entry against a rider who was never created - in the money
-- tables. That is the same class as effective_cash_limit_v1, which was guarded only in application
-- code and leaked. This closes it in the database instead.
--
-- Four small functions rather than one parameterised helper. A helper would need dynamic SQL to
-- resolve the discriminator to a table name, and that puts an interpolated identifier into EXECUTE.
-- Static EXISTS per discriminator cannot be injected, and each function is four lines.
--
-- Performance: one extra primary-key lookup per insert. wallets, payouts and commission_rules are
-- low-frequency, and ledger_entries gets one lookup per entry written. All four are indexed lookups
-- on a primary key, so this is not measurable against the write path.
--
-- The error is a single generic code, FOREIGN_KEY_VIOLATE. It deliberately does not say whether the
-- row was missing or whether the id exists in some other table, so a caller cannot use it to
-- enumerate ids. The discriminator is echoed only because the caller supplied it themselves.

create or replace function private.assert_wallet_owner()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.owner_id is null then
    return null;
  end if;
  if new.owner_type = 'vendor' and not exists (select 1 from public.vendors where id = new.owner_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: wallet owner' using errcode = '23503';
  end if;
  if new.owner_type = 'rider' and not exists (select 1 from public.riders where id = new.owner_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: wallet owner' using errcode = '23503';
  end if;
  return null;
end $$;

create trigger trg_wallets_assert_owner before insert or update on public.wallets
  for each row execute function private.assert_wallet_owner();

create or replace function private.assert_payout_account()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.payout_type = 'vendor' and not exists (select 1 from public.vendors where id = new.account_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: payout account' using errcode = '23503';
  end if;
  if new.payout_type = 'rider' and not exists (select 1 from public.riders where id = new.account_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: payout account' using errcode = '23503';
  end if;
  return null;
end $$;

create trigger trg_payouts_assert_account before insert or update on public.payouts
  for each row execute function private.assert_payout_account();

-- Depends on the account_id nullability fix below, so it is created after that.
create or replace function private.assert_ledger_account()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.account_type = 'vendor' and not exists (select 1 from public.vendors where id = new.account_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: ledger account' using errcode = '23503';
  end if;
  if new.account_type = 'rider' and not exists (select 1 from public.riders where id = new.account_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: ledger account' using errcode = '23503';
  end if;
  return null;
end $$;

create or replace function private.assert_commission_target()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- target_id is null for a platform-wide default, which is the documented meaning of null.
  if new.scope = 'vendor' and new.target_id is not null
     and not exists (select 1 from public.vendors where id = new.target_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: commission target' using errcode = '23503';
  end if;
  if new.scope = 'rider' and new.target_id is not null
     and not exists (select 1 from public.riders where id = new.target_id) then
    raise exception 'FOREIGN_KEY_VIOLATE: commission target' using errcode = '23503';
  end if;
  return null;
end $$;

create trigger trg_commission_rules_assert_target before insert or update on public.commission_rules
  for each row execute function private.assert_commission_target();

revoke execute on function private.assert_wallet_owner() from public, anon, authenticated;
revoke execute on function private.assert_payout_account() from public, anon, authenticated;
revoke execute on function private.assert_ledger_account() from public, anon, authenticated;
revoke execute on function private.assert_commission_target() from public, anon, authenticated;

-- =============================================================================================
-- a vacuous CHECK, and a NOT NULL that contradicted its own comment
-- =============================================================================================
-- 009 added this to ledger_entries:
--
--   constraint ledger_entries_platform_has_no_account check (
--     account_type not in ('platform','platform_earnings') or account_id is not null)
--
-- It enforces the OPPOSITE of its name, and it cannot fail. account_id is declared NOT NULL, so
-- "account_id is not null" is a tautology, so the OR is always true, so the CHECK is dead code that
-- reads like a safety guarantee. Found by reading pg_get_constraintdef back rather than trusting the
-- migration I had just written - the definition in the file and the constraint in the database are
-- both correct and the two do not mean what the name says.
--
-- The root cause is a contradiction in data-model.md 7 itself:
--
--   account_id uuid not null,   -- vendor_id, rider_id, or NULL for platform accounts
--
-- A NOT NULL column whose comment describes NULL for platform accounts. The comment is the intent -
-- a platform_earnings aggregate belongs to no vendor and no rider, so it has no owner - and the
-- NOT NULL is the error. Resolved in favour of the comment, so account_id becomes nullable and the
-- CHECK finally means something: a vendor or rider entry MUST name its owner, and a platform entry
-- MUST NOT.
--
-- Dropping NOT NULL on a column of an empty table is a catalogue-only change. No rewrite, no lock
-- worth mentioning, no backfill.
alter table public.ledger_entries
  alter column account_id drop not null;

alter table public.ledger_entries
  drop constraint ledger_entries_platform_has_no_account;

alter table public.ledger_entries
  add constraint ledger_entries_account_required check (
    (account_type in ('vendor','rider') and account_id is not null)
    or (account_type in ('platform','platform_earnings') and account_id is null)
  );

create trigger trg_ledger_entries_assert_account before insert or update on public.ledger_entries
  for each row execute function private.assert_ledger_account();

-- =============================================================================================
-- open question 3.15, resolved as KEEP bigserial - reversing an earlier recommendation
-- =============================================================================================
-- Not changed, and this reverses what I recommended when I raised it. The reasoning then was "UUIDs or
-- another safe distributed ID strategy", and both tables are empty so the change is free now. Both
-- halves of that were weighed and neither survives contact with the schema.
--
-- The security half is not worth anything here, and saying so plainly matters more than looking
-- thorough. Nothing has a foreign key to notifications or to rider_location_pings, so no query can
-- join through a guessed id. Both tables will be reached by (user_id, created_at) - the inbox - or by
-- an age sweep, and a sequential id appearing in a URL grants an attacker nothing they could not get
-- by guessing a uuid either, because the RLS policy filters on user_id regardless of which id was
-- supplied. Enumeration only becomes a leak if some future RPC exposes a row by id WITHOUT a
-- user filter, and that is an RPC bug, not an id-scheme problem. Migration 014's policies are the
-- control that actually matters, and 013's dispatcher writes are the second.
--
-- The performance half is real and points the other way. uuid is 128 bits against bigint's 64, so
-- every index on these two tables roughly doubles, and these are the highest-volume prune targets in
-- the database: notifications is budgeted at 6 rows per order and rider_location_pings at 20. Paying
-- that forever to defend against an attack that does not apply is the wrong trade.
--
-- rider_location_pings additionally receives zero rows until Phase 8, when the tracking API exists.
--
-- So: bigserial stays, and 014's policies carry the security weight. Recorded so the decision is
-- visible rather than looking like an oversight.

-- =============================================================================================
-- open question 3.16, resolved as KEEP the uuid[]
-- =============================================================================================
-- Also not changed. The measurement in 011 stands: GIN on uuid[] is accepted and used for the
-- vendor-membership branch, and the "applies to all vendors" branch cannot use any index. A join
-- table would fix the half that is already fine and would need a sentinel convention for the half
-- that is not - and a wrong sentinel silently hides a voucher from every vendor or shows it to every
-- vendor. With tens of vouchers rather than millions, the sequential scan on "all vendors" is free
-- forever, so the trade is a permanent index-size cost against a cost that will never be paid.
-- vouchers.applies_to_vendor_ids and driver_shifts.area_ids both stay as arrays.