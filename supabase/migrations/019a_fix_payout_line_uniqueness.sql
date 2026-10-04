-- =============================================================================================
-- 019a_fix_payout_line_uniqueness.sql
-- =============================================================================================
-- 019 made payout_lines_assignment_unique UNIQUE on (assignment_id) alone. That is wrong, and the
-- first rider payout proved it by aborting.
--
-- THE BUG. One trip legitimately produces more than one payout line: a 'rider_trip' line for the
-- pay earned and a 'tip' line for the customer's tip, both pointing at the same delivery_assignment.
-- A single-column UNIQUE therefore forbids a trip from having a tip at all. The first rider payout
-- with a non-zero tip failed with
--   duplicate key value violates unique constraint "payout_lines_assignment_unique"
--   Key (assignment_id)=(...) already exists
-- and aborted the whole transaction. Not a live-money bug - 019 has never been exercised in
-- production and every fixture runs inside a rolled-back transaction - but it would have shipped a
-- function that cannot pay a tipped rider, which is most of them.
--
-- THE FIX. Uniqueness is per (assignment_id, payout_line_type). One trip may carry one rider_trip
-- line, one tip line and one bonus line, and no more than one of each. That is exactly the guarantee
-- wanted, and it is strictly the protection 019 was reaching for:
--
--   same trip in two payout batches  -> violates on (assignment_id, 'rider_trip')
--   same tip paid twice              -> violates on (assignment_id, 'tip')
--   a trip line plus its own tip     -> allowed, which is correct
--
-- This is the rider-side equivalent of payout_lines_sub_order_unique, which is single-column on
-- sub_order_id because one vendor leg earns exactly one line type.
--
-- WHY NOT PARTIAL-EXCLUDE tip/bonus INSTEAD. Excluding them would leave a tip with no double-payment
-- guard at all, which is the failure this whole column was added to prevent. Per-type uniqueness
-- guards every line type.
--
-- 019 IS NOT EDITED. It is applied and committed, so this is a forward migration, in the same spirit
-- as 005a, 007a, 010a, 014a and 018a.
-- =============================================================================================

drop index if exists public.payout_lines_assignment_unique;

create unique index payout_lines_assignment_unique
  on public.payout_lines (assignment_id, payout_line_type)
  where assignment_id is not null;