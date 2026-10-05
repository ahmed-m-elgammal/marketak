-- 038: the push drain. `notification-routing-table.md` §8.3 and §8.9 Phase 1.
--
-- THREE FUNCTIONS, NO SCHEMA CHANGE, and the names are the spec's own: `register_device_token_v1`,
-- `claim_events_v1`, `mark_events_delivered_v1`. `tasks.md` T3.5 and `data-model.md` 14.4 already name
-- the last two. An earlier draft of the plan renamed them `claim_push_batch_v1` / `mark_push_sent_v1`,
-- which was wrong twice: it forked a name the spec had committed to, and a drain that also claims 53
-- admin audit events is not a "push batch".
--
-- WHY FIRST. Nothing about push works until a client can register a token. `authenticated` holds
-- exactly one grant on `device_tokens` and it is SELECT, and the two policies on that table
-- (`device_tokens_read`, `device_tokens_admin_read`) carry no `with_check`, so no client can insert.
-- This migration is the blocker, not a step towards it.
--
-- =============================================================================================
-- WHAT IS REUSED, NOT REBUILT
-- =============================================================================================
--   * `events` already has `delivered_at`, `attempts`, `last_error`, and the two indexes this work
--     needs: `events_undelivered (created_at) WHERE delivered_at IS NULL` is the claim filter and its
--     ordering, `events_delivered_at (delivered_at, created_at)` is the prune's.
--   * `notification_templates` is populated - 19 keys x ar/en, every one active, every one carrying a
--     declared `variables` array. Verified by query, not assumed.
--   * `private.err(code, message)` for every refusal, so a client sees a `contracts.md` code.
--   * `private.notification_type_exists(text)` exists and has ZERO callers. Wired up here rather than
--     reimplemented.
--   * `private.is_admin()` is deliberately NOT used. These are not admin functions, and consulting it
--     would be a privilege escalation rather than a gate.
--
-- =============================================================================================
-- THE THREE GRANTS, AND WHY TWO OF THEM DEPART FROM THE CONVENTION
-- =============================================================================================
-- `register_device_token_v1`  -> `authenticated`. A client calls it. `anon` refused.
--
-- `claim_events_v1`, `mark_events_delivered_v1`  -> `service_role` ONLY. This is the first departure
-- from the repository's convention, so it is argued rather than asserted.
--
--   All 82 existing `_v1` functions are `authenticated`-callable, and every one of them is correct: a
--   client asking for its own order to be placed is what they are for. These two are different,
--   because `events` has EXACTLY ONE POLICY - `events_admin_read`, a SELECT policy gated on
--   `private.is_admin()` - and **no INSERT or UPDATE policy at all**. Verified against `pg_policy`:
--   `events` has one row and its `polcmd` is `r`.
--
--   Granting EXECUTE on these two to `authenticated` would let any signed-in user:
--
--     * call `mark_events_delivered_v1` and mark arbitrary events delivered, silently suppressing every
--       notification those events would ever have produced, and
--     * do so without `attempts` ever incrementing, so `free-tier-plan.md` 11 item 8 - "Undelivered
--       `events` older than 1 hour: Any" - could never fire. An alarm that cannot ring is worse than no
--       alarm, because it reads as healthy.
--
--   `service_role` carries `BYPASSRLS`, so both functions reach `events` as themselves. P1.8 asserts
--   the privilege from the catalog rather than trusting the migration text, because a granted EXECUTE
--   on a `security definer` function is exactly the class of defect `027` shipped, and the pattern a
--   future author will copy from the other 82 is `grant execute ... to authenticated, service_role`.
--
-- `REVOKE AFTER CREATE`, per `037`'s finding: this project's `pg_default_acl` for `public` functions is
-- `postgres=X | anon=X | authenticated=X | service_role=X`, so `create or replace function` grants
-- EXECUTE to `anon` by itself and a revoke written BEFORE the create is undone by it.
--
-- =============================================================================================
-- WHY THE COLLAPSE KEY IS `payload->>'order_id'` AND NEVER `aggregate_id`
-- =============================================================================================
-- Measured against the live emitters:
--
--   event                   aggregate_type   aggregate_id      payload->>'order_id'
--   order.status_changed    sub_order        the sub_order_id  present
--   order.placed            order            the order_id      present
--   order.claimed           order            the order_id      present
--   order.delivered         order            the order_id      present
--   order.cancelled         order            the order_id      present
--
-- Two `aggregate_type` values sit inside the routed set, so grouping on `aggregate_id` would mix a
-- sub_order uuid with an order uuid in one column and collapse nothing at all. `payload->>'order_id'`
-- is present in every emitter, which is what makes it the only correct key.
--
-- WHY IT MATTERS. `transition_order_v1(p_order_id, p_sub_order_id, p_to_status, p_reason)` takes ONE
-- sub_order and emits ONE `order.status_changed`. A 3-vendor checkout therefore emits three `accepted`,
-- three `preparing`, three `ready`, three `picked_up`. Routed naively that is up to 24 customer pushes
-- for a single order. Claimed grouped, it is one push per routed type.
--
-- =============================================================================================
-- WHY THE DISPLAY VALUES COME FROM A JOIN
-- =============================================================================================
-- Nine of the routed rows need a variable the payload does not carry. `eta` is in seven templates and
-- no payload; `order_number` in four and no payload; `vendor_name` and `rider_name` in five and none.
-- Widening the emitters means editing nine live function bodies and would bloat every `events` row with
-- denormalised display strings that are true for one recipient and stale for the next. So the claim
-- joins instead - once per collapsed notification, not once per event.
--
-- `riders` is read directly rather than through `riders_public`. ADR 20 gives clients the view and
-- removes the table's client grants entirely; `claim_events_v1` runs with `BYPASSRLS` and needs no
-- view. Had this been `authenticated`-callable, `rider_name` would have had to come from the view's
-- projection instead - same three columns, different table. Recorded because it is the one place where
-- the grant decision changes the SQL and not only the privilege.
--
-- NO `begin;` / `commit;` IN THIS FILE. One implicit transaction per file, per `data-model.md` 15.1, so
-- a failing assertion leaves nothing installed.

-- ---------------------------------------------------------------------------
-- 1. register_device_token_v1
-- ---------------------------------------------------------------------------
-- WHY `on conflict (token)` AND NOT `(user_id, token)`. `device_tokens_token_key` is
-- `UNIQUE (token)` - one token, one row, globally. There is no composite `(user_id, token)` index and
-- the constraint forbids what that key implies: a token cannot belong to two users, so re-registering
-- under a new account must UPDATE the row's owner, never create a second one. `device_tokens_user_id_
-- app_role_idx` is `(user_id, app_role)` - for routing, not for upsert. The plan had this wrong until
-- it was checked against `pg_indexes`, and the error would have surfaced as a unique violation the
-- first time a client re-registered.
--
-- WHY `language` IS READ RATHER THAN ACCEPTED. `device_tokens.language` is `not null` with no default
-- and it is the column the Worker renders from. Accepting it as an argument would let a client choose
-- the language its own notifications arrive in; the row's language is a fact about the user, so it is
-- read from `users.preferred_language`. That cross-table read is why this is `security definer`.
--
-- WHY `p_app_role` IS NARROWED. `device_tokens_app_role_check` permits `{customer, rider, admin}` and
-- this function cannot narrow it - the constraint is existing schema. Restricting the ARGUMENT
-- constrains what a client may register, not what a row may hold, and that weaker guarantee is stated
-- rather than claimed. Nothing routes to an `admin` token (§8.4), so such a row would sit unread rather
-- than mis-deliver.
--
-- WHY ONE TOKEN PER ROLE. Routing resolves the recipient from `app_role`, so a customer token that
-- silently started receiving rider messages would be a mis-delivery, not a duplicate.
create or replace function public.register_device_token_v1(
  p_token        text,
  p_platform     text,
  p_app_role     text,
  p_app_version  text default null
)
returns table (id uuid, token text, platform text, app_role text, language text, last_seen_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := (select auth.uid());
  v_language text;
  v_row      public.device_tokens%rowtype;
begin
  if v_user is null then
    perform private.err('AUTH_REQUIRED', 'sign in first');
  end if;

  if p_token is null or btrim(p_token) = '' then
    perform private.err('TOKEN_REQUIRED', 'a push token is required');
  end if;
  if length(btrim(p_token)) > 4096 then
    perform private.err('TOKEN_TOO_LONG', 'push token is longer than 4096 characters');
  end if;

  -- Checked here rather than left to the CHECK, so the client gets a named code instead of a raw
  -- `device_tokens_platform_check` violation it cannot map to anything.
  if p_platform is null or p_platform not in ('android', 'ios') then
    perform private.err('PLATFORM_INVALID', 'platform must be android or ios');
  end if;
  if p_app_role is null or p_app_role not in ('customer', 'rider') then
    perform private.err('APP_ROLE_INVALID', 'app_role must be customer or rider');
  end if;

  if exists (
    select 1 from public.device_tokens t
     where t.user_id = v_user
       and t.app_role = p_app_role
       and t.token <> btrim(p_token)
  ) then
    perform private.err('TOKEN_ALREADY_REGISTERED',
      'another device is registered for this role; sign out on that device first');
  end if;

  select u.preferred_language into v_language
    from public.users u where u.id = v_user;
  if v_language is null then
    perform private.err('PROFILE_INCOMPLETE', 'set a preferred language before registering for push');
  end if;

  insert into public.device_tokens
    (user_id, token, platform, app_role, app_version, language, last_seen_at)
  values
    (v_user, btrim(p_token), p_platform, p_app_role, p_app_version, v_language, now())
  on conflict (token) do update
     set user_id       = excluded.user_id,
         platform      = excluded.platform,
         app_role      = excluded.app_role,
         app_version   = excluded.app_version,
         language      = excluded.language,
         last_seen_at  = now()
  returning * into v_row;

  return query
    select v_row.id, v_row.token, v_row.platform, v_row.app_role, v_row.language, v_row.last_seen_at;
end;
$$;

comment on function public.register_device_token_v1(text, text, text, text) is
  'Register or refresh this device''s push token. Upserts on (token), which is globally UNIQUE. '
  'language is read from users.preferred_language and never accepted from the client.';

-- ---------------------------------------------------------------------------
-- 2. private.push_routing - the routing table, as data
-- ---------------------------------------------------------------------------
-- In SQL rather than in the Worker, so it is one place, testable, and cannot drift from the database.
-- `free-tier-plan.md` 5.3 forbids doing in a Worker what Postgres can aggregate, and choosing a
-- recipient is exactly that.
--
-- `v_payload_to` is matched with `is not distinct from`, so a NULL row matches only a NULL
-- `payload->>'to'`. That is what keeps `order.placed` from being read as a transition. `order.status_
-- changed` genuinely carries `to`, so without the NULL-safe comparison the two `order.placed` rows
-- below would both fire on a transition as well as on placement.
--
-- AN EVENT WITH NO ROW HERE IS NEVER ROUTED. That is how the seven deferred messages (§8.1.2) and the
-- five unrouted templates (§8.1.3) stay off without a second mechanism to disable them.
create or replace function private.push_routing()
returns table (
  v_event_type   text,
  v_payload_to   text,
  v_recipient    text,
  v_template_key text
)
language sql
stable
set search_path = ''
as $$
  select * from (values
    -- rider
    ('order.claimed',       null::text,    'rider',    'rider.order_assigned'),
    -- customer
    ('order.placed',        null,          'customer', 'order.placed'),
    ('order.status_changed','rejected',    'customer', 'order.vendor_rejected'),
    ('order.status_changed','picked_up',   'customer', 'order.picked_up'),
    ('order.delivered',     null,          'customer', 'order.delivered'),
    ('order.cancelled',     null,          'customer', 'order.cancelled'),
    -- vendor
    ('order.placed',        null,          'vendor',   'vendor.new_order')
  ) as t(v_event_type, v_payload_to, v_recipient, v_template_key);
$$;

comment on function private.push_routing() is
  'The MVP routing table, seven rows. An event matching no row is never routed, so the deferred and '
  'unrouted templates need no second mechanism to stay off.';

-- ---------------------------------------------------------------------------
-- 3. claim_events_v1
-- ---------------------------------------------------------------------------
-- RETURNS ONE ROW PER NOTIFICATION, not per event. That is the collapse rule made visible: N events
-- sharing a `payload->>'order_id'` and a routed type produce one row whose `event_ids` array holds every
-- id folded into it. `mark_events_delivered_v1` then marks exactly those ids and nothing else.
--
-- WHY `event_ids` IS AN ARRAY AND NOT A COUNT. The Worker must mark precisely what it sent, and a
-- partially-failed group must leave its failures claimable. A count cannot identify rows.
--
-- WHY THE TEMPLATE IS INNER-JOINED. `private.notification_type_exists` gates the claim, so an event
-- whose template key is absent or inactive is not claimable and stays `delivered_at is null` -
-- deliberately left in the undelivered backlog so `free-tier-plan.md` 11 item 8 counts it. Dropping it
-- silently would make a broken routing entry invisible, which is the failure mode P1.7 exists to catch.
--
-- `for update of e skip locked` inside the `routing` CTE is the claim. Two concurrent callers cannot
-- take the same row, and the lock is released at the end of the calling transaction.
create or replace function public.claim_events_v1(p_limit int default 50)
-- BROKEN AS APPLIED. Two defects, both found by executing the body rather than reading it, and both
-- corrected in `038a_push_drain_assertions.sql`:
--   1. The `routing` CTE selects `e.v_recipient` and `e.v_template_key`, but `events` has NEITHER
--      column - they come from `private.push_routing()`. Every call raised
--      `ERROR 42703: column e.v_recipient does not exist`.
--   2. The vendor expansion used `min(so.vendor_id)`, and PostgreSQL has NO `min(uuid)`. The body did
--      not even compile: `ERROR 42883: function min(uuid) does not exist`.
-- The body is left exactly as applied. An applied migration is immutable, and `017a`/`017b` exist
-- because editing applied text after the fact is how a repository starts describing work that never
-- ran.
returns table (
  event_ids     bigint[],
  template_key  text,
  recipient     text,
  recipient_id  uuid,
  order_id      uuid,
  order_number  text,
  variables     jsonb,
  language      text,
  oldest_event  timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit int;
begin
  v_limit := greatest(1, least(coalesce(p_limit, 50), 200));

  return query
  with routing as (
    -- THE CLAIM. `for update of e skip locked` is the mutual exclusion; `events_undelivered` is the
    -- index serving both the filter and this ordering.
    select e.id, e.type, e.payload, e.created_at, r.v_recipient, r.v_template_key
      from public.events e
      join private.push_routing() r
        on  r.v_event_type = e.type
        and r.v_payload_to is not distinct from (e.payload ->> 'to')
     where e.delivered_at is null
       -- Not claimable while its template is missing or inactive. See the header.
       and private.notification_type_exists(r.v_template_key)
       -- An event with no order_id cannot be collapsed and has no recipient to resolve, so it is not
       -- claimable either. Every current emitter sets it.
       and (e.payload ? 'order_id')
     order by e.created_at, e.id
     limit v_limit
       for update of e skip locked
  ), addressed as (
    -- A claim row has no recipient yet, and the vendor recipient is per-sub_order's vendor rather than
    -- per order. So the addressee is resolved HERE, before the collapse, and the vendor half is
    -- EXPANDED: one row per distinct vendor on the order.
    --
    -- This ordering is the whole reason the vendor fan-out works. Resolving the vendor after the
    -- collapse would collapse a 3-vendor `order.placed` into one row with one arbitrarily-chosen
    -- vendor, and two vendors would never hear about the order. Expanding first and collapsing second
    -- gives three vendor rows and one customer row, which is a fan-out rather than a duplicate.
    select r.id, r.created_at, r.v_recipient, r.v_template_key,
           (r.payload ->> 'order_id')::uuid as order_id,
           o.user_id                       as customer_id,
           vc.vendor_id                    as vendor_id
      from routing r
      join public.orders o on o.id = (r.payload ->> 'order_id')::uuid
      left join lateral (
        -- Distinct, so a vendor appearing on two sub-orders of one order is still one notification.
        select min(so.vendor_id) as vendor_id
          from public.sub_orders so
         where so.order_id = (r.payload ->> 'order_id')::uuid
         group by so.vendor_id
      ) vc on r.v_recipient = 'vendor'
  ), collapsed as (
    -- THE COLLAPSE. One row per (recipient, recipient_id, template, order). Three sub-orders reaching
    -- `picked_up` on one order is one push, carrying all three ids.
    select a.v_recipient,
           a.v_template_key,
           a.order_id,
           array_agg(a.id order by a.id) as event_ids,
           min(a.created_at)             as oldest_event,
           case a.v_recipient
             when 'customer' then a.customer_id
             when 'vendor'   then a.vendor_id
             when 'rider'    then (select da.rider_id
                                    from public.delivery_assignments da
                                   where da.order_id = a.order_id and da.rider_id is not null
                                   order by da.assigned_at nulls last
                                   limit 1)
           end                          as recipient_id
      from addressed a
     -- Grouped on the resolved addressee, NOT on the routing alone. This is the difference between one
     -- notification and three: without the addressee in the key, all three vendors of one order share
     -- a group and exactly one of them is ever told.
     group by a.v_recipient, a.v_template_key, a.order_id, 6
  ), resolved as (
    -- The display join, once per collapsed notification rather than once per event.
    select c.*,
           o.order_number,
           o.total,
           o.vendor_count,
           o.item_count,
           o.payment_method,
           o.promised_delivery_at,
           v.name as vendor_name,
           (select trim(both ' ' from coalesce(r2.first_name,'') || ' ' || coalesce(r2.last_name,''))
              from public.riders r2
              join public.delivery_assignments da on da.rider_id = r2.id
             where da.order_id = c.order_id
             order by da.assigned_at nulls last
             limit 1) as rider_name,
           (select jsonb_array_length(coalesce(da.stop_sequence, '[]'::jsonb))
              from public.delivery_assignments da
             where da.order_id = c.order_id and da.rider_id is not null
             order by da.assigned_at nulls last
             limit 1) as stops
      from collapsed c
      join public.orders o on o.id = c.order_id
      left join public.vendors v on v.id = c.recipient_id and c.v_recipient = 'vendor'
  )
  select r.event_ids,
         r.v_template_key,
         r.v_recipient,
         r.recipient_id,
         r.order_id,
         r.order_number,
         -- `jsonb_strip_nulls` so a template variable the join could not supply is ABSENT rather than
         -- present-and-null. A missing key is a renderer error; a null is a silent empty string, which
         -- is how an Arabic message ends up with a hole in it.
         jsonb_strip_nulls(jsonb_build_object(
           'order_number',   r.order_number,
           'vendor_count',   r.vendor_count,
           'total',          r.total,
           'vendor_name',    r.vendor_name,
           'rider_name',     nullif(r.rider_name, ''),
           'stops',          case when r.stops > 0 then r.stops end,
           'eta',            case when r.promised_delivery_at is not null
                                     then to_char(r.promised_delivery_at at time zone 'UTC', 'HH24:MI')
                                end,
           'payment_method', r.payment_method,
           'item_count',     r.item_count
         )),
         -- `preferred_language` is ar/en and both rows exist for all 19 keys, so this fallback is
         -- unreachable in practice. It is here so a missing row degrades to English rather than
         -- raising inside the drain and stalling every subsequent notification.
         coalesce(
           (select t.lang from public.notification_templates t
             where t.key = r.v_template_key and t.channel = 'push' and t.is_active
               and t.lang = (select u.preferred_language from public.users u where u.id = r.recipient_id)),
           'en'
         ),
         r.oldest_event
    from resolved r
   -- A collapsed row with no resolved recipient cannot be delivered to anyone. Left unclaimed rather
   -- than marked, so the backlog keeps showing it.
   where r.recipient_id is not null;
end;
$$;

comment on function public.claim_events_v1(int) is
  'Claim a batch of undelivered events and return ONE ROW PER NOTIFICATION: events sharing an order_id '
  'and a routed type are collapsed into one row. service_role only.';

-- ---------------------------------------------------------------------------
-- 4. mark_events_delivered_v1
-- ---------------------------------------------------------------------------
-- ONE call per batch, per `free-tier-plan.md` 5.2's "marks its whole claimed batch in one RPC".
--
-- `p_result` is an array of `{event_id, ok, error}`. `p_ids` is the set the caller believes it sent;
-- only ids present in BOTH are marked. That is what makes a partially-failed group recoverable: the
-- ids the Worker failed on are simply absent from `p_ok`, so they stay `delivered_at is null` and are
-- claimable again on the next drain. A design that took a single `ok boolean` for the batch could not
-- express that, and marking the whole batch on one failure would silently drop notifications.
--
-- `attempts` increments on every appearance so `free-tier-plan.md` 3.2's "alert above 5" threshold has
-- something to count, and so a notification that keeps failing is visible before it is pruned.
create or replace function public.mark_events_delivered_v1(
  p_ids   bigint[],
  p_result jsonb default null
)
returns table (marked bigint, still_open bigint)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ok    bigint[];
  v_bad   bigint[];
  v_marked integer := 0;
  v_open   integer := 0;
begin
  if p_ids is null or cardinality(p_ids) = 0 then
    perform private.err('IDS_REQUIRED', 'p_ids must name the events that were attempted');
  end if;

  -- Default to "everything succeeded" so a caller that has no per-event detail to report still gets a
  -- correct mark, and a caller that does report detail gets the partial behaviour.
  v_ok := coalesce(
    (select array_agg((x->>'event_id')::bigint)
       from jsonb_array_elements(p_result) x
      where coalesce((x->>'ok')::boolean, false)),
    p_ids);

  -- Anything attempted but not reported as ok stays open. Explicit, rather than implied by absence.
  v_bad := (select array_agg(id) from unnest(p_ids) id where not (id = any (v_ok)));

  -- `delivered_at >= created_at` is a CHECK on `events`, so now() is always a legal value and this
  -- cannot fail the constraint; it is stated rather than defended against.
  update public.events e
     set delivered_at = now(),
         attempts     = e.attempts + 1,
         last_error   = null
   where e.id = any (v_ok)
     and e.delivered_at is null;

  get diagnostics v_marked = row_count;

  if v_bad is not null then
    update public.events e
       set attempts   = e.attempts + 1,
           last_error = left(coalesce(
             (select x->>'error' from jsonb_array_elements(p_result) x
               where (x->>'event_id')::bigint = e.id and not coalesce((x->>'ok')::boolean, false)),
             'send failed'), 500)
     where e.id = any (v_bad);

    get diagnostics v_open = row_count;
  end if;

  return query select v_marked::bigint, v_open::bigint;
end;
$$;

comment on function public.mark_events_delivered_v1(bigint[], jsonb) is
  'Mark one claimed batch delivered. Only ids present in BOTH p_ids and p_result[].ok are marked; '
  'attempted ids reported as failed keep delivered_at NULL and stay claimable. service_role only.';

-- ---------------------------------------------------------------------------
-- 5. Grants - AFTER the creates, per 037
-- ---------------------------------------------------------------------------
revoke execute on function public.register_device_token_v1(text, text, text, text) from public, anon;
revoke execute on function public.claim_events_v1(int)                                      from public, anon, authenticated;
revoke execute on function public.mark_events_delivered_v1(bigint[], jsonb)                from public, anon, authenticated;

grant execute on function public.register_device_token_v1(text, text, text, text) to authenticated, service_role;
grant execute on function public.claim_events_v1(int)                                      to service_role;
grant execute on function public.mark_events_delivered_v1(bigint[], jsonb)                to service_role;

alter default privileges in schema public revoke execute on functions from anon;

-- Read back from the catalog rather than trusted from the text above. This is the whole point of P1.8.
do $$
declare
  v_leaked text;
begin
  select string_agg(r, ', ' order by r) into v_leaked
    from unnest(array[
      'public.register_device_token_v1(text,text,text,text)',
      'public.claim_events_v1(int)',
      'public.mark_events_delivered_v1(bigint[],jsonb)']) as x(r)
   where has_function_privilege('anon', r, 'EXECUTE');

  if v_leaked is not null then
    raise exception 'FAIL CLOSED: anon can EXECUTE %. Revoke after create, not before.', v_leaked;
  end if;

  select string_agg(r, ', ' order by r) into v_leaked
    from unnest(array[
      'public.claim_events_v1(int)',
      'public.mark_events_delivered_v1(bigint[],jsonb)']) as x(r)
   where has_function_privilege('authenticated', r, 'EXECUTE');

  if v_leaked is not null then
    raise exception
      'FAIL CLOSED: authenticated can EXECUTE %. A client could mark events delivered, suppressing '
      'notifications and holding attempts flat so 11 item 8 can never fire.', v_leaked;
  end if;

  if not has_function_privilege('service_role', 'public.claim_events_v1(int)', 'EXECUTE') then
    raise exception 'FAIL CLOSED: service_role cannot claim; the drain has no caller';
  end if;
end $$;

-- =============================================================================================
-- Assertions moved to `038a_push_drain_assertions.sql`
-- =============================================================================================
-- =============================================================================================
-- The behavioural probe this file originally carried is NOT in its applied text, and a file that
-- claims a test the database never ran is the `017a` defect: a diff of the file describes work that
-- did not happen. `038` was applied without its probe, so the probe ships as a separate migration
-- that stands on its own and can be re-run at any time.
--
-- The one assertion `038` DOES carry is the `do` block above: the grant read-back. That ran, and it
-- is what makes the `service_role`-only grants a verified fact rather than an intention.
