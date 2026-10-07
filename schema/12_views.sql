-- =============================================================================
-- 12_views.sql
-- The only view in the application schema.
-- =============================================================================

-- Customer-visible rider identity. It deliberately omits user_id,
-- current_latitude, current_longitude, cash_held and max_cash_held.
-- phone_number IS exposed because the customer pays the rider at the door and
-- must be able to call them.
create view public.riders_public as
 SELECT id,
    first_name,
    last_name,
    phone_number,
    vehicle_type,
    vehicle_plate,
    rating_avg,
    rating_count
   FROM riders
  WHERE is_active;

comment on view public.riders_public is 'Rider identity for customers: name, vehicle, rating, phone. Deliberately excludes user_id, current_latitude, current_longitude, cash_held and max_cash_held. Phone is exposed because the customer pays at the door and must be able to call.';