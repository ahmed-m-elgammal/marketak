-- 011s_seed_notification_templates.sql
-- DATA ONLY. No DDL, per data-model.md §15.1 rule 1.
--
-- notification_templates has been empty since 010 created it, and nothing in §15.2 would ever have
-- populated it. That is a gap in its own right, independent of open question 3.12: nothing can render
-- a notification until these rows exist.
--
-- 3.12 resolved as option (a'): the RPC validates notifications.type against THIS table rather than
-- against a list hardcoded into a CHECK. That keeps the catalogue in the database, where the templates
-- already live, so adding the 20th notification type is an insert rather than a migration.
--
-- 19 keys from contracts.md §4.1-4.3, each in ar and en, which is the primary market language first
-- per data-model.md §1 ("the Arabic value is the default everywhere").
--
-- channel is 'push' for all of these. §4.4 requires every push to have an in-app fallback, and it
-- needs no template of its own: notifications.title and body are stored already rendered, so the
-- same template produces both.
--
-- THE ARABIC IS A FIRST DRAFT AND WANTS REVIEW by someone who writes Arabic customer-facing copy.
-- It is grammatically correct MSA and the placeholders match contracts.md exactly, but nobody should
-- ship customer-facing Arabic that a native speaker has not read. Every row can be corrected with an
-- UPDATE and no code change - which is the whole reason these are rows and not constants.
--
-- on conflict (key, channel, lang) do update, matching 002s: re-running this file cannot fail, and a
-- corrected translation can be applied by re-running it.

insert into public.notification_templates (key, channel, lang, title, body, variables) values
-- ---------- customer: contracts.md 4.1 ----------
('order.placed', 'push', 'ar', 'تم استلام طلبك',
 'طلبك {order_number} قيد التحضير من {vendor_count} مطعم. الإجمالي {total}.',
 '["order_number","vendor_count","total"]'::jsonb),
('order.placed', 'push', 'en', 'Order received',
 'Your order {order_number} is being prepared by {vendor_count} vendor(s). Total {total}.',
 '["order_number","vendor_count","total"]'::jsonb),

('order.vendor_accepted', 'push', 'ar', 'تم قبول طلبك',
 'وافق {vendor_name} على طلبك. الوصول المتوقع {eta}.',
 '["vendor_name","eta"]'::jsonb),
('order.vendor_accepted', 'push', 'en', 'Vendor accepted',
 '{vendor_name} accepted your order. Estimated arrival {eta}.',
 '["vendor_name","eta"]'::jsonb),

('order.vendor_rejected', 'push', 'ar', 'تغيّر طلبك',
 'رفض {vendor_name} جزءًا من طلبك: {affected_items}. مطلوب منك {action_required}.',
 '["vendor_name","affected_items","action_required"]'::jsonb),
('order.vendor_rejected', 'push', 'en', 'Your order changed',
 '{vendor_name} declined part of your order: {affected_items}. You need to {action_required}.',
 '["vendor_name","affected_items","action_required"]'::jsonb),

('order.preparing', 'push', 'ar', 'طلبك قيد التحضير',
 'يتم تحضير طلبك الآن. الوصول المتوقع {eta}.',
 '["eta"]'::jsonb),
('order.preparing', 'push', 'en', 'Being prepared',
 'Your order is being prepared now. Estimated arrival {eta}.',
 '["eta"]'::jsonb),

('order.ready', 'push', 'ar', 'طلبك جاهز',
 'طلبك جاهز للتسليم. الوصول المتوقع {eta}.',
 '["eta"]'::jsonb),
('order.ready', 'push', 'en', 'Order ready',
 'Your order is ready for pickup. Estimated arrival {eta}.',
 '["eta"]'::jsonb),

('order.picked_up', 'push', 'ar', 'انطلق مندوب التوصيل',
 'استلم {rider_name} طلبك. الوصول المتوقع {eta}.',
 '["rider_name","eta"]'::jsonb),
('order.picked_up', 'push', 'en', 'Courier on the way',
 '{rider_name} has collected your order. Estimated arrival {eta}.',
 '["rider_name","eta"]'::jsonb),

('order.arriving', 'push', 'ar', 'مندوب التوصيل قريب',
 'مندوب التوصيل على بعد كيلومترين. الوصول المتوقع {eta}.',
 '["eta"]'::jsonb),
('order.arriving', 'push', 'en', 'Courier is close',
 'Your courier is about 2 km away. Estimated arrival {eta}.',
 '["eta"]'::jsonb),

('order.delivered', 'push', 'ar', 'تم التوصيل',
 'تم تسليم طلبك. الإجمالي {total}. طريقة الدفع {payment_method}. {review_prompt}',
 '["total","payment_method","review_prompt"]'::jsonb),
('order.delivered', 'push', 'en', 'Delivered',
 'Your order has been delivered. Total {total}. Paid by {payment_method}. {review_prompt}',
 '["total","payment_method","review_prompt"]'::jsonb),

('order.cancelled', 'push', 'ar', 'تم إلغاء الطلب',
 'تم إلغاء طلبك: {reason}. المبلغ المسترد {refund_amount}.',
 '["reason","refund_amount"]'::jsonb),
('order.cancelled', 'push', 'en', 'Order cancelled',
 'Your order was cancelled: {reason}. Refunded {refund_amount}.',
 '["reason","refund_amount"]'::jsonb),

('voucher.available', 'push', 'ar', 'عرض متاح',
 'استخدم الكود {code} قبل {expires_at}.',
 '["code","expires_at"]'::jsonb),
('voucher.available', 'push', 'en', 'Promotion available',
 'Use code {code} before {expires_at}.',
 '["code","expires_at"]'::jsonb),

-- ---------- vendor: contracts.md 4.2 ----------
('vendor.new_order', 'push', 'ar', 'طلب جديد',
 'طلب {order_number}: {item_count} عنصر بإجمالي {total}. التسليم المطلوب {prep_deadline}.',
 '["order_number","item_count","total","prep_deadline"]'::jsonb),
('vendor.new_order', 'push', 'en', 'New order',
 'Order {order_number}: {item_count} item(s), total {total}. Prep deadline {prep_deadline}.',
 '["order_number","item_count","total","prep_deadline"]'::jsonb),

('vendor.order_cancelled', 'push', 'ar', 'تم إلغاء طلب',
 'ألغى العميل الطلب: {reason}. العناصر: {items}.',
 '["reason","items"]'::jsonb),
('vendor.order_cancelled', 'push', 'en', 'Order cancelled',
 'The customer cancelled: {reason}. Items: {items}.',
 '["reason","items"]'::jsonb),

('vendor.order_modified', 'push', 'ar', 'تغيّر في الطلب',
 'تغيّر {item_name} من {old} إلى {new}.',
 '["item_name","old","new"]'::jsonb),
('vendor.order_modified', 'push', 'en', 'Order changed',
 '{item_name} changed from {old} to {new}.',
 '["item_name","old","new"]'::jsonb),

('vendor.payout_paid', 'push', 'ar', 'تم تحويل مستحقاتك',
 'تم تحويل {amount} عن الفترة {period}.',
 '["amount","period"]'::jsonb),
('vendor.payout_paid', 'push', 'en', 'Payout sent',
 '{amount} has been transferred for {period}.',
 '["amount","period"]'::jsonb),

-- ---------- rider: contracts.md 4.3 ----------
('rider.new_offer', 'push', 'ar', 'طلب قريب منك',
 'طلب جديد: استلام من {pickup_area} وتوصيل إلى {delivery_area}. Earnings {rider_pay_total}.',
 '["pickup_area","delivery_area","rider_pay_total"]'::jsonb),
('rider.new_offer', 'push', 'en', 'Order near you',
 'New order: pickup {pickup_area}, delivery {delivery_area}. Earnings {rider_pay_total}.',
 '["pickup_area","delivery_area","rider_pay_total"]'::jsonb),

('rider.order_assigned', 'push', 'ar', 'تم إسناد طلب إليك',
 'تم إسناد الطلب {order_number} إليك. عدد المحطات {stops}. Earnings {rider_pay_total}.',
 '["order_number","stops","rider_pay_total"]'::jsonb),
('rider.order_assigned', 'push', 'en', 'Order assigned',
 'Order {order_number} is yours. {stops} stop(s). Earnings {rider_pay_total}.',
 '["order_number","stops","rider_pay_total"]'::jsonb),

('rider.customer_cancelled', 'push', 'ar', 'سقط طلب',
 'ألغى العميل الطلب {order_number}. المحطات المتبقية {stops_remaining}.',
 '["order_number","stops_remaining"]'::jsonb),
('rider.customer_cancelled', 'push', 'en', 'Order dropped',
 'The customer cancelled order {order_number}. {stops_remaining} stop(s) remaining.',
 '["order_number","stops_remaining"]'::jsonb),

('rider.payout_paid', 'push', 'ar', 'تم تحويل مستحقاتك',
 'تم تحويل {amount}. النقد المحصّل {cash_remitted}.',
 '["amount","cash_remitted"]'::jsonb),
('rider.payout_paid', 'push', 'en', 'Payout sent',
 '{amount} has been transferred. Cash collected {cash_remitted}.',
 '["amount","cash_remitted"]'::jsonb),

('rider.cash_limit_warning', 'push', 'ar', 'تنبيه حد النقد',
 'النقد المحصّل {cash_held} من أصل {effective_cash_limit}.',
 '["cash_held","effective_cash_limit"]'::jsonb),
('rider.cash_limit_warning', 'push', 'en', 'Cash limit warning',
 'You are holding {cash_held} of a {effective_cash_limit} limit.',
 '["cash_held","effective_cash_limit"]'::jsonb)
on conflict (key, channel, lang) do update
  set title = excluded.title,
      body = excluded.body,
      variables = excluded.variables,
      updated_at = now();