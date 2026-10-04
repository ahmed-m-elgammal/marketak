-- 005a_fix_bump_menu_version.sql
--
-- Bug in 005: bump_menu_version() referenced new.item_id unconditionally, but
-- menu_categories has no item_id column. PL/pgSQL resolves record fields at RUNTIME, so the
-- trigger and all five CREATE TRIGGER statements succeeded, and the function only failed when a
-- category was actually inserted. Found by executing 005 against the live project, not by
-- reading it.
--
-- The fix reads the row as jsonb, where a missing key yields NULL instead of raising. That makes
-- one function safe across all five catalog tables without five near-identical functions.
--
-- This is a separate file rather than an edit to 005 because 005 has already been applied.
-- data-model.md 15.1 rule 3: migrations are immutable once applied.

create or replace function public.bump_menu_version()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_rec    jsonb;
  v_item   uuid;
  v_vendor uuid;
begin
  v_rec := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;

  -- A category change bumps its vendor directly; there is no parent item to walk up to.
  if tg_table_name = 'menu_categories' then
    update public.vendors
       set menu_version = menu_version + 1, updated_at = now()
     where id = (v_rec ->> 'vendor_id')::uuid;
    return null;
  end if;

  v_item := case
              when tg_table_name = 'menu_items' then (v_rec ->> 'id')::uuid
              else (v_rec ->> 'item_id')::uuid
            end;

  -- option_choices hangs off an option, not an item, so it needs one extra hop.
  if tg_table_name = 'option_choices' then
    v_item := (select o.item_id
                 from public.item_options o
                where o.id = (v_rec ->> 'option_id')::uuid);
  end if;

  select mi.vendor_id into v_vendor from public.menu_items mi where mi.id = v_item;

  if v_vendor is not null then
    update public.vendors
       set menu_version = menu_version + 1, updated_at = now()
     where id = v_vendor;
  end if;

  return null;
end;
$$;
