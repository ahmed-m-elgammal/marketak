# ⛔ SUPERSEDED — DO NOT IMPLEMENT FROM THIS FILE

> **This is the original v1 architecture spec. It has been superseded by
> `specs/001-platform-foundation/`.**
>
> Read `AGENTS.md` first. Where this document and the current spec disagree, **the current spec
> wins.** This file is retained only because its free-tier arithmetic is still a useful sanity check,
> and the current `free-tier-plan.md` supersedes it with better numbers anyway.
>
> ### It contradicts the current spec on these points
>
> | This file says | The current spec says | See |
> |---|---|---|
> | `merchants` + `merchant_branches` | `vendors`, one location each | ADR 7 |
> | Firebase Remote Config for flags | A `feature_flags` table | ADR 8 |
> | Live tracking in v1 | Phase 8, flag default off | ADR 9 |
> | A customer wallet with top-ups and admin verification | **No customer wallet. The customer pays the rider directly** | ADR 2 |
> | No `sub_orders`; one order per merchant | `orders` + N `sub_orders` | ADR 1 |
> | No delivery-fee formula | `base × multiplier(vendor_count)` | ADR 4 |
> | Commission 0% for everyone | A rider cut is **active** at launch; vendor commission lands at month 3–4 | ADR 3 |
> | Email and password auth | Google and Apple only | ADR 6 |
> | Commission modelled but inert | `ledger_entries`, `payouts`, `platform_float` | ADR 11 |
>
> ### Also stale
>
> - Free-tier limits were "taken from pricing pages in October 2026" and were never measured
> - Region, project name, bucket names and account IDs did not exist when this was written
> - The whole order-placement, payment and settlement model predates the money decisions

---

# Food Delivery Platform: Architecture Spec v1

**Stack:** Supabase + Cloudflare + Firebase
**App:** React Native (Expo): customer app, driver app, merchant app (plus admin web)
**Market:** Egypt (Arabic and English)
**Status:** Planning spec. All usage numbers are estimates, and all free-tier limits were taken from the providers' pricing pages in October 2026. Re-check them before launch because providers change them.

---

## 0. Scope

**In scope:** the three services (Supabase, Cloudflare, Firebase), the role of each one, and how they work together.

**Out of scope for v1:** any online payment gateway. Orders in v1 are paid by `cash` or `wallet`. The design leaves a clean slot to add a gateway later (see section 6.4), so nothing needs to be rebuilt.

### Design principles

1. **One source of truth.** Supabase owns all business data and the only login. Cloudflare and Firebase hold copies or short-lived state only.
2. **Degrade, don't fail.** If Cloudflare or Firebase is down, ordering and money still work. Only images, live tracking or push degrade.
3. **Each service has one job.** No feature is split across two services unless one is clearly the owner and the other is a delivery channel.
4. **Free first, upgrade by signal.** Everything runs on free tiers at the start. Section 9 lists exactly when to pay and for what.
5. **Cheap-now decisions.** Anything that is painful to change once real orders exist (money format, state machine, outbox, branches) is decided in this spec.

---

## 1. System overview

```
              Customer / Driver / Merchant apps (React Native + Expo)
                   |                   |                    |
                   v                   v                    v
        +--------------------+  +--------------------+  +--------------------+
        |     SUPABASE       |  |    CLOUDFLARE      |  |      FIREBASE      |
        |  System of record  |  | Edge and delivery  |  |  Device services   |
        |--------------------|  |--------------------|  |--------------------|
        | Postgres + RLS     |  | R2 + CDN           |  | FCM                |
        | Auth               |  | Durable Objects    |  | Crashlytics        |
        | RPC + pg_cron      |  | Workers            |  | Analytics          |
        | Search (Arabic)    |  | Pages              |  | Remote Config      |
        +--------------------+  +--------------------+  +--------------------+
```

### Role summary

| Service | One-line role | Owns | Must never own |
|---|---|---|---|
| Supabase | System of record | Data, identity, business rules, scheduled jobs, search | Image bytes, live WebSocket traffic |
| Cloudflare | Edge and delivery | Files, CDN, live channels, event relay | The only copy of any business data |
| Firebase | Device services | Push delivery, crash and usage telemetry, remote switches | Authoritative settings, user data, money rules |

### How the pieces talk to each other

| From | To | How | Why |
|---|---|---|---|
| Apps | Supabase | Supabase client: Auth, PostgREST, RPC | All reads and writes of business data |
| Apps | Cloudflare | HTTPS (CDN) for images and menus, WebSocket for tracking | Fast delivery without touching the database |
| Apps | Firebase | Firebase SDKs | Push token, crash reports, analytics, remote config |
| Supabase | Cloudflare | Database webhook (Postgres trigger using `pg_net`) to a Worker on every new `events` row | Single, reliable channel for all side effects |
| Cloudflare Workers | Supabase | HTTPS with a service-role key (stored as a Worker secret) | Mark events delivered, read data for snapshots, export data |
| Cloudflare Workers | Firebase | FCM HTTP v1 API | Send push notifications |

---

## 2. Supabase: system of record

### 2.1 What it is in this app

Supabase is the brain and the memory of the platform. It stores every business fact (users, merchants, menus, orders, wallet, reviews), decides what is allowed (login, row-level permissions, order state changes, prices and fees), runs scheduled jobs, and answers search queries. Nothing else in the architecture is allowed to decide or remember a business fact.

### 2.2 Postgres + Row Level Security (RLS)

#### What

All business data lives in Postgres, in these groups of tables:

| Group | Tables |
|---|---|
| Identity | `profiles`, `addresses`, `device_tokens`, `driver_documents` |
| Merchants | `merchants`, `merchant_branches`, `merchant_staff`, `operating_hours`, `merchant_categories` |
| Catalog | `categories`, `items`, `item_options`, `item_option_choices` |
| Orders | `orders`, `order_items`, `order_status_history` |
| Money | `ledger_entries`, `promo_codes`, `promoted_slots` |
| Engagement | `favorites`, `favorite_items`, `reviews`, `notifications` (inbox), `notification_templates` |
| Drivers | `drivers`, `driver_shifts` |
| Rules | `delivery_zones`, `fee_rules` |
| Platform | `events` (outbox) |

#### How

**Conventions (apply to every table):**
- Money is stored as an integer in piastres, with a `currency` column (`EGP` by default). No floats.
- Public IDs are UUIDs.
- Timestamps are `timestamptz` in UTC. Each city has a timezone column used only for display and opening hours.
- Every table has `created_at`, `updated_at` and `deleted_at` (soft delete). Menu snapshots, sync and archiving all depend on `updated_at`.
- Translatable text is `jsonb`, for example `{"ar": "...", "en": "..."}`. A third language later needs no migration.

**Merchants vs branches.** `merchants` is the brand. `merchant_branches` holds location, hours link, delivery zone link and an active flag. Items are shared by the merchant and can be overridden per branch (availability, price). `merchant_staff` is a many-to-many table (user, merchant or branch, role) so one person can work at several places and a branch can have several staff.

**The wallet is a ledger.** `ledger_entries` is append-only: entry id, account (customer, driver, merchant, platform), signed amount, type (`topup`, `order_payment`, `cash_collected`, `commission`, `refund`, `driver_payout`, `merchant_payout`, `adjustment`), order reference, idempotency key, created at. Balances are computed from entries (with a cached balance column updated in the same transaction). Entries are never updated or deleted; mistakes are fixed by a new reversing entry.

**The order state machine lives in the database.** Allowed transitions:

```
pending  -> accepted | rejected | cancelled
accepted -> preparing | cancelled
preparing -> ready | cancelled
ready    -> picked_up
picked_up -> delivered
```

Only a function `transition_order(order_id, new_status, actor)` can change status. It checks the table of allowed transitions and the actor's role, writes `order_status_history`, and writes an `events` row, all in one transaction. Apps have no direct write access to `orders.status`.

**Order fields that keep payments open for later:** `payment_method` (`cash`, `wallet` in v1), `payment_status` (`unpaid`, `paid`, `refunded`), and a nullable `payment_provider` / `provider_reference` pair that stays empty in v1.

**The outbox.** Every meaningful change writes a row to `events` in the same transaction as the change: `order.placed`, `order.status_changed`, `driver.assigned`, `menu.updated`, `promo.created`, and so on. A row has an id, type, payload (`jsonb`), `created_at`, `delivered_at` (null until a consumer confirms), and an attempt counter. This is how Supabase tells the outside world anything, so a Worker being down loses nothing: the event waits.

**RLS policies (summary):**

| Actor | Can read | Can write |
|---|---|---|
| Customer | Own profile, addresses, orders, reviews, favorites, notifications; all public catalog | Own profile, addresses, favorites, device tokens; orders only through RPC |
| Merchant staff | Orders and data for their branches | Menu items, availability, hours for their branches; order status only through `transition_order` |
| Driver | Own profile, shifts, assigned orders, open orders near them | Own location status, device tokens; order claim and status only through RPC |
| Admin | Everything | Everything, through RPC where money is involved |

**Geography.** Delivery zones and "nearest driver" use PostGIS `geography(Point)` if the extension is available on your project (verify in the dashboard). If not, use lat/lng with a bounding-box prefilter and a haversine calculation in SQL.

#### Why

- Orders, wallet and payouts are relational and need real transactions. An order, its items, a ledger hold and an outbox event must succeed or fail together. Postgres does this natively.
- RLS puts security in the data layer, so a bug in an app can't leak another customer's order.
- A ledger plus an outbox plus a database-enforced state machine are the three decisions that are the most painful to retrofit once real orders exist.
- Integer money and `jsonb` translations avoid whole classes of rounding and migration problems.

### 2.3 Auth

#### What

The one and only identity system for customers, drivers, merchants and admins.

#### How

- Methods: email and password, Google sign-in, Apple sign-in. Password reset and email verification are enabled.
- Native sign-in on mobile: obtain the ID token with the native Google and Apple SDKs, then exchange it with Supabase (`signInWithIdToken`) so users don't see a browser window.
- Custom SMTP is configured (included on the free plan) so emails come from your own domain and don't hit the built-in email limits.
- The user's role is stored on `profiles` (and in `merchant_staff` for staff scope) and is available to RLS. The JWT carries the user id; Workers verify it locally.
- A new `auth.users` row triggers creation of the matching `profiles` row.
- Free-plan note: 50,000 monthly active users are included. At 1,500-2,000 daily users you are far below that.

#### Why

- A single identity system means every other service can trust one token. Cloudflare Workers only need to verify a Supabase JWT; they never manage passwords.
- Having Firebase Auth as a second login would duplicate users and break RLS. It is deliberately not used.

### 2.4 RPC (Postgres functions) and pg_cron

#### What

Supabase runs all business logic as Postgres functions called via RPC, and all scheduled work with `pg_cron`.

#### How

**RPC catalogue (versioned names, for example `place_order_v1`):**

| Function | Purpose |
|---|---|
| `get_merchant_feed_v1` | Paginated, sorted merchant list for a city or location |
| `get_fee_preview_v1` | Delivery fee, platform fee and discounts for a cart and address |
| `validate_promo_v1` | Check a promo code against the cart and user |
| `place_order_v1` | Re-price the cart server-side, validate items and hours and zone, create order, items and a ledger hold (for wallet), write the `order.placed` event. No external call is needed in v1 |
| `cancel_order_v1` | Apply cancellation rules and fees, release or refund wallet entries |
| `transition_order_v1` | The only way to change order status (accept, prepare, ready, pick up, deliver) |
| `driver_claim_order_v1` | Atomically assign an open order to one driver (a single `UPDATE ... WHERE driver_id IS NULL`, so two drivers can't both win) |
| `set_default_address_v1` | Atomic default address swap |
| `get_review_summary_v1` | Aggregated ratings for a merchant |
| `search_catalog_v1` | Arabic and English search (section 2.5) |
| `can_track_order_v1` | Does this user have the right to follow this order live? Used by the Cloudflare tracking gate |
| `claim_undelivered_events_v1` | Hands a batch of undelivered events to a Worker (retry path) |
| `export_orders_before_v1`, `mark_orders_archived_v1` | Archive support (section 6.6) |

Versioned names mean older app versions keep working when a function changes.

**Scheduled jobs (`pg_cron`):**

| Job | Schedule | What it does |
|---|---|---|
| Stale orders | every 5 min | Cancels `pending` orders nobody accepted within the configured window |
| Promo expiry | hourly | Deactivates expired promos |
| Loyalty promos | daily | Issues loyalty rewards |
| Driver settlements | daily or weekly | Writes `driver_payout` ledger entries |
| Merchant payouts | daily or weekly | Writes `merchant_payout` ledger entries |
| Inbox pruning | daily | Deletes `notifications` older than 30 days |

**Edge Functions are not used in v1.** With no payment gateway there is no external API call that has to happen inside a transaction, so every operation is a Postgres function. This keeps the free Edge Function quota (500,000 calls/month) untouched and reserved for a future gateway.

#### Why

- Business logic next to the data runs in one transaction, with no network hop and no half-finished states.
- RPC calls count as ordinary API requests, which are unlimited on the free plan, whereas Edge Function calls are capped.
- Price and fee rules live in tables (`fee_rules`, `delivery_zones`), not code, so a new city or category is new rows, not a release.

### 2.5 Search

#### What

Restaurant and item search in Arabic and English, inside Postgres.

#### How

- Each searchable row gets a normalized text column built by a function that strips Arabic diacritics (tashkeel), unifies alef variants (ا أ إ آ), unifies ya and alef maqsura, and unifies ta marbuta and ha, lowercases Latin text, and removes punctuation.
- A trigram index (`pg_trgm`) handles typos and partial matches. The `unaccent` extension handles Latin accents.
- `search_catalog_v1(query, city, limit)` returns merchants and items ranked by similarity, with open-now and distance as tie-breakers.
- Alternative for later: ship a compact search index file from R2 and search on-device (section 3.1).

#### Why

- At 200 merchants and 20,000 items, Postgres search is more than fast enough and costs nothing extra.
- It avoids a separate paid search service that your earlier Firebase-only plan would have needed.

### 2.6 Free-tier limits and how to handle them

| Limit (Free) | Value | Impact | Handling |
|---|---|---|---|
| Database size | 500 MB | The one real wall | Trim notification rows, keep status history compact, archive old orders to R2 (section 6.6). Upgrade to Pro when near 400 MB |
| Egress | 5 GB/month | OK once menus and images are served from Cloudflare | Keep list responses small, paginate |
| Edge Function calls | 500,000/month | Unused in v1 | Reserved |
| Realtime | 200 connections, 2M messages/month | Not used for tracking | Tracking runs on Durable Objects |
| Backups | None | Risk for wallet and orders | Nightly export to R2 (section 3.3), and Pro before launch |
| Inactivity pause | After 1 week idle | Matters only before launch | Keep staging active, Pro for production |
| Active projects | 2 | Not enough for dev, staging and prod | Develop locally with the Supabase CLI, one staging project, production on Pro |
| Logs | 1 day | Short debugging window | Write important business events to your own tables |

**Production recommendation:** move to Supabase Pro ($25/month) before launch with real money. It includes an 8 GB disk, 100,000 monthly active users, daily backups kept 7 days, and no pausing. Point-in-time recovery is an add-on starting at $100/month and is worth considering once the wallet holds real balances.

---

## 3. Cloudflare: edge and delivery

### 3.1 R2 + CDN: files and fast delivery

#### What

R2 is object storage with a global CDN in front of it. It holds every file the app shows and every large JSON file, so none of that traffic touches the database.

| Bucket | Access | Contents |
|---|---|---|
| `public` | Public through a custom domain on Cloudflare (for example `cdn.yourdomain.com`) | Item and merchant images, avatars, menu snapshot JSON, optional search index |
| `private` | Never public; signed short-lived URLs only | Driver documents (ID, licence), nightly exports, archived orders |

#### How

**Key layout (public bucket):**

```
img/merchants/{merchant_id}/logo-{hash}.webp
img/items/{merchant_id}/{item_id}-{hash}.webp
img/avatars/{user_id}-{hash}.webp
menus/{merchant_id}/v{menu_version}.json
search/index-v{n}.json            (optional, section 3.1 "Search index")
```

- File names include a content hash or a version number, so every file is immutable and served with `Cache-Control: public, max-age=31536000, immutable`. A changed image or menu gets a new URL; nothing ever needs purging.
- The database stores only the path (for example `img/items/…webp`), never the bytes.

**Images.** The app resizes and compresses on the device before upload (max 800 px on the long side, WebP, target around 30 KB). The upload goes to a signed URL issued by the `upload-signer` Worker (section 3.3), which checks the Supabase JWT and that the user is staff of that merchant. Supabase Free has no image transformations, so resizing on the device is how you keep files small.

**Menu snapshots.** One JSON file per merchant containing categories, items, options, translations, prices and availability, and no user-specific data. About 60 KB raw (roughly 10-15 KB compressed) for 100 items. The merchant feed from Supabase returns each merchant's `menu_version`; the app builds the URL `menus/{merchant_id}/v{menu_version}.json`, downloads it once, and caches it on the device. Menu changes bump the version, which creates a new URL.

**Staleness is safe by design.** The snapshot is for display only. At checkout `place_order_v1` re-reads real prices and availability from Postgres and rejects or corrects anything that changed.

**Private files.** The `file-access` Worker checks the caller's role (for example admin for driver documents) and returns a signed URL that expires in a few minutes.

**Search index (optional).** A compact file (merchant and item names only, normalized the same way as in section 2.5) of roughly 200-800 KB that the app can download once and search offline with a small client-side library. Use it only if you want zero-server search; Postgres search is the default.

#### Why

- R2 has no egress fees and includes 10 GB of storage plus 1 million write and 10 million read operations per month for free.
- Images were the first thing that would have broken Supabase Free: at your target traffic they are roughly 26-172 GB/month against a 5 GB cached-egress cap. On R2 the same traffic is free.
- Menu snapshots remove the heaviest read path (opening a menu) from the database completely.
- Immutable, versioned URLs mean caching just works, on the CDN and on the device.

#### Limits (Free) and estimates

| Limit | Cap | Estimated use |
|---|---|---|
| Storage | 10 GB | 1-2 GB (20,000 images at 30-50 KB is 0.6-1 GB, plus logos, snapshots, exports) |
| Write operations | 1M/month | Well under 200K |
| Read operations | 10M/month | 1.2-3.6M before CDN cache hits |
| Egress | Free | n/a |

Confirm at signup whether Cloudflare asks for a payment method to enable R2, and plan to put a domain on Cloudflare for the CDN (a domain is likely the only unavoidable cash cost).

### 3.2 Durable Objects: live tracking

#### What

A Durable Object (DO) is a small stateful program with its own WebSocket connections, living at the edge. It is the live channel between driver, customer and merchant for an active order. It is a delivery channel, not a database: the truth stays in Supabase.

Two classes:

| Class | One object per | Used for |
|---|---|---|
| `OrderRoom` | Active order | Driver location, status changes, customer and merchant live view |
| `BranchInbox` | Merchant branch | Live "new order" list on the merchant app and web dashboard |

#### How

**Connecting.** The app opens `wss://track.yourdomain.com/order/{order_id}` with its Supabase JWT. The `tracking-gate` Worker verifies the JWT locally, calls `can_track_order_v1` with the user's JWT (so RLS decides), and only then forwards the connection to the object. The role (customer, driver, merchant) is attached to the socket. Each connection costs one Worker request.

**Messages.**
- Driver to room: `{ "t": "loc", "lat": …, "lng": …, "heading": …, "ts": … }`. The room accepts it only from the socket whose role is the assigned driver.
- Room to customer and merchant: the latest location and every status change. Each message carries the `event_id` so clients can ignore duplicates.
- Dispatcher to room: status events arrive over an internal HTTP call protected by a shared secret.
- On connect the room immediately sends the current state (last location and status), so reconnects are instant. Clients should also call the Supabase RPC to confirm the order status after reconnecting.

**Hibernation is mandatory.** Use the WebSocket Hibernation API (`ctx.acceptWebSocket`) and never a plain `accept()`. A plain `accept()` is billed for duration the whole time a socket is connected, which would exhaust the free duration allowance quickly. With hibernation an idle object costs nothing.

**Persistence.** The latest point lives in memory (and in the socket attachment). One point per minute is written to the object's SQLite storage for route replay. When the order is delivered or cancelled the room sends a final message, saves a route summary to Supabase once (`save_route_summary_v1`), and schedules its own cleanup after about 10 minutes.

**Driver ping policy.**
- Ping every 15 seconds while the order is `picked_up`, and optionally while heading to the merchant after accepting.
- Never ping when there is no active order.
- Interval and minimum distance (about 25 m) are Remote Config values, so you can slow pings to save battery or quota without a release.

**BranchInbox.** Merchant apps and dashboards connect when open. The dispatcher pushes `order.placed` into the right inbox. If the merchant isn't connected, FCM push still goes out, and the app always calls `list_branch_orders_v1` when it comes to the foreground.

#### Why

- Supabase Realtime on Free allows only 200 connections and 2 million messages/month. Driver pings every 15 seconds would use an estimated 2.9-5.9 million messages/month at your target volume, so it would fail in the first weeks.
- Durable Objects on the free plan allow 100,000 requests/day and 13,000 GB-seconds/day of duration, with incoming WebSocket messages billed at 20 to 1 and outgoing messages free. That is roughly 8 billed requests per order, about 16,000/day at 2,000 orders.
- One object per order isolates traffic, and objects disappear when the order ends.
- Free-plan Durable Objects are SQLite-backed only, which is exactly what this design uses.

#### Limits (Free) and estimates

| Limit | Cap | Estimated use at 2,000 orders/day |
|---|---|---|
| Requests | 100K/day | ~16K/day |
| Duration | 13,000 GB-s/day | Small, provided hibernation is used |
| Rows written | 100K/day | ~40K/day (one location point per minute per active order) |
| Storage | 5 GB total | Negligible (objects clean themselves up) |

### 3.3 Workers: the glue

#### What

Workers are small, always-on programs at the edge that move events and files between the services. They carry things; they never decide business rules.

| Worker | Job |
|---|---|
| `outbox-dispatcher` | Receives the database webhook for every new `events` row and runs the side effects for that event type |
| `tracking-gate` | Verifies the JWT and tracking permission, then hands the WebSocket to the right Durable Object |
| `upload-signer` | Issues signed upload URLs to R2 after checking role and ownership |
| `snapshot-builder` | Rebuilds a merchant's menu JSON and writes it to R2 |
| `file-access` | Issues short-lived signed URLs for private files after a role check |
| `export-jobs` (Cron Triggers) | Nightly backup export and nightly order archive; every-minute retry of undelivered events |

#### How

**The outbox dispatcher.** Postgres triggers on `events` use `pg_net` (Supabase Database Webhooks) to POST each new row to the Worker. By event type:

| Event | Side effects |
|---|---|
| `order.placed` | FCM to staff of the branch, push into `BranchInbox` |
| `order.status_changed` | FCM to the customer (and driver when relevant), push into `OrderRoom` |
| `order.accepted` | FCM to nearby online drivers (list from `get_nearby_drivers_v1`) |
| `driver.assigned` | FCM to the driver and customer, push into `OrderRoom` |
| `menu.updated` | Call `snapshot-builder` for that merchant |
| `promo.created` | FCM to the target audience (batched) |

After a successful run the Worker calls `mark_event_delivered_v1(event_id)`. If anything fails the event simply stays undelivered. A Cron Trigger every minute calls `claim_undelivered_events_v1(20)` and retries. Delivery is at-least-once, so every consumer is idempotent (event id is the idempotency key, FCM uses a collapse key, and clients ignore duplicate `event_id`).

**Sending push (FCM).** The Worker calls the FCM HTTP v1 API. It needs a short-lived Google access token, obtained by signing a JWT with the Firebase service account key using WebCrypto. Cache that token for about 55 minutes. Message text is rendered from `notification_templates` in Supabase in the user's `preferred_language`. If a send returns "token not registered", the Worker calls `remove_device_token_v1`.

**Free-plan constraints to design around.**
- 10 ms CPU time per request: keep Workers I/O-bound, verify JWTs with WebCrypto, cache the Google token, and test the signing step under load.
- 50 subrequests per request: process at most about 20 events per invocation.
- 100,000 requests/day is a hard stop with no overage: never route images or menu files through Workers, and keep alerting at 70% of the daily cap.
- 5 Cron Triggers per account: this design uses 3.
- If the CPU limit makes FCM signing unreliable, the documented fallback is to send push from a Supabase Edge Function instead (cost: Edge Function quota, which is unused in v1).

**Secrets (Worker secrets, never in the app):** Supabase service-role key, Firebase service-account key, the shared secret for internal Durable Object calls, and the database-webhook secret.

**Nightly jobs.**
- *Export:* incremental export of `ledger_entries`, `orders`, `order_items`, `profiles`, `merchants`, `items` (by `updated_at`) as compressed JSON lines into `private/backups/YYYY-MM-DD/`, kept for 30 days.
- *Archive:* move order details older than about 60 days to R2 (section 6.6).

#### Why

- Workers are always on, with no pausing and no cold-start problems for webhooks.
- Putting side effects here keeps them off Supabase's quotas (Edge Functions are capped at 500,000 calls/month on Free).
- The outbox plus retry means a Worker outage delays a notification but never loses it.
- Estimated use is about 23,000 requests/day at 2,000 orders (7 dispatcher calls and 3 tracking connections per order, plus cron and uploads), about a quarter of the free cap.

### 3.4 Pages: admin and merchant web

#### What

Static web dashboards hosted on Cloudflare Pages. One for the admin team, one for merchants.

#### How

- A React single-page app built to static files. Sign-in uses Supabase Auth; every read and write goes through RPC and RLS, so there is no separate backend.
- **Merchant dashboard:** live order list (connects to `BranchInbox`), accept/reject and status buttons (`transition_order_v1`), menu and price editor, availability toggles, opening hours, simple reports.
- **Admin dashboard:** merchant and branch onboarding, driver verification (documents via signed URLs), promo and fee-rule management, order monitor, ledger and payout views, Remote Config reminders.
- Static assets on Pages cost nothing and bandwidth is not metered. The free plan includes 500 builds/month.

#### Why

- Merchants and staff don't have to install the app or update it, and the admin side never ships inside the consumer app.
- It is free, and it reuses the same Supabase login and permissions.

---

## 4. Firebase: device services

### 4.0 What Firebase is (and is not) in this app

Firebase is the toolbox for the phone: it delivers push notifications, reports crashes, measures behavior and flips remote switches. It runs on the **Spark (no-cost) plan with no payment method**. Spark does not include Cloud Functions or Cloud Storage, and this design doesn't need them. Firestore, Realtime Database, Firebase Auth and Hosting are deliberately not used, because Supabase and Cloudflare own those jobs.

### 4.1 Firebase Cloud Messaging (FCM): push notifications

#### What

The delivery pipe for push notifications to Android and iOS.

#### How

- **Tokens.** Each app registers a device token after the user grants notification permission, and stores it through an RPC in `device_tokens` (`user_id`, `token`, `platform`, `app_role`, `app_version`, `language`, `last_seen`). Tokens are refreshed on every app start and removed on sign-out or when FCM reports them invalid. Android uses the FCM token. iOS needs an APNs authentication key uploaded in the Firebase console (requires an Apple Developer account).
- **Sending.** Only the `outbox-dispatcher` Worker sends. The server credentials never exist inside an app.
- **Message design.** Data payload carries `type`, `order_id` and a deep link, and the title and body are rendered server-side from `notification_templates` in the user's language (Arabic or English). Android notification channels per category (orders, promotions, driver offers) let users control them.
- **Catalogue.**

| Audience | Notifications |
|---|---|
| Customer | Order accepted, preparing, ready, picked up, delivered, cancelled; promotions |
| Merchant | New order, order cancelled by customer |
| Driver | New order nearby, order assigned, order cancelled |

#### Why

- FCM is free with no meaningful volume limits, and it is the native push channel on Android and the standard route to APNs on iOS.
- Push makes the app work even when a live connection is closed: it is the safety net under the Durable Object channels.

### 4.2 Crashlytics: crash and error reports

#### What

Automatic crash reporting from all three apps, plus non-fatal error logging.

#### How

- Use React Native Firebase with an Expo development build (it does not run inside Expo Go). The project already has a `google-services.json`; add the iOS plist as well.
- Set custom keys on every report: `app_role` (customer, driver, merchant), app version and build, current screen, and the active `order_id`. Use a hashed user id and never log personal data (phone, address, name).
- Log non-fatal errors for failed RPC calls and for WebSocket drops, so you see problems that don't crash the app.
- Upload source maps in the build pipeline so stack traces are readable. Turn on alerts for new and regressing crashes.

#### Why

- It is free, and it groups crashes by cause so you see which bug affects the most users.
- With three apps, filtering by `app_role` and version shows which release introduced a problem.

### 4.3 Analytics: usage and funnels

#### What

Behavior measurement: what people look at, where they drop off, and who returns.

#### How

- Standard events plus custom ones: `view_merchant`, `search`, `add_to_cart`, `begin_checkout`, `promo_applied`, `order_placed`, `order_delivered`, `review_submitted`, `driver_online`, `driver_order_accepted`.
- User properties: `app_role`, `city`, `language`, `app_version`.
- Core funnel: `view_merchant` to `add_to_cart` to `begin_checkout` to `order_placed`.
- No personal data in events or properties. Show a consent prompt if your legal review requires it.
- Business truth (orders, revenue, payouts) comes from Supabase, never from Analytics.

#### Why

- It is free, and it answers product questions (which screens lose users, which cities grow) without building anything.
- Keeping money numbers in Supabase avoids relying on sampled or delayed analytics data.

### 4.4 Remote Config: switches without a release

#### What

A small set of settings and flags the apps read at startup, changeable instantly from the Firebase console.

#### How

Fetch on cold start and when returning to the foreground (respecting the SDK's minimum fetch interval), keep safe defaults inside the app, and fall back to the last good values if a fetch fails.

| Key | Purpose |
|---|---|
| `min_app_version_android`, `min_app_version_ios`, `force_update`, `update_url` | Force-update screen for old versions |
| `maintenance_mode`, `maintenance_message_ar`, `maintenance_message_en` | Planned maintenance banner |
| `cdn_base_url`, `tracking_ws_url` | Where to find Cloudflare services, so you can repoint without a release |
| `live_tracking_enabled`, `search_enabled`, `reviews_enabled`, `wallet_enabled`, `cash_enabled` | Feature flags and kill switches |
| `driver_ping_interval_sec` (default 15), `driver_ping_min_distance_m` (default 25) | Tracking cost and battery control |
| `menu_cache_ttl_min` | How long the app trusts a cached menu before re-checking the version |

**Rule:** Remote Config values are public and non-authoritative. Never put fees, prices, discounts, permissions or anything secret in it. Those live in Supabase tables and are enforced in the database.

#### Why

- Instant rollback and kill switches are the cheapest insurance for a live delivery app, and they avoid waiting for an app-store review.
- The free plan allows 100,000 fetches per day per project; at around 4,000 sessions/day you use a few percent of that.

---

## 5. Cross-service contracts

### 5.1 The event contract

`events` is the only way Supabase talks to the outside world.

| Field | Meaning |
|---|---|
| `id` | UUID, used as the idempotency key everywhere downstream |
| `type` | `order.placed`, `order.accepted`, `order.status_changed`, `driver.assigned`, `menu.updated`, `promo.created`, … |
| `payload` | `jsonb` with the ids and the minimum data a consumer needs (never secrets) |
| `created_at` | Ordering within one order |
| `delivered_at` | Null until the dispatcher confirms |
| `attempts` | Retry counter; alert when an event exceeds a threshold |

Guarantees: **at-least-once** delivery. Consumers must tolerate duplicates (FCM collapse keys, clients ignoring a repeated `event_id`, snapshot builds being safe to repeat).

### 5.2 The auth contract

1. The app signs in with Supabase Auth and receives a JWT.
2. Workers verify the JWT locally (signature, expiry, audience) and read the user id.
3. For anything that needs permission (tracking an order, uploading a menu image, viewing a private document), the Worker asks Supabase through an RPC with the user's own JWT, so RLS and role rules decide. Workers never trust a role sent by the client.
4. Workers use the service-role key only for system work (marking events delivered, claiming retries, exporting).

### 5.3 Where each secret lives

| Secret | Lives in | Never in |
|---|---|---|
| Supabase service-role key | Worker secrets | Apps, git |
| Firebase service-account key | Worker secrets | Apps, git |
| Internal shared secret (Worker to Durable Object) | Worker secrets | Apps |
| Database-webhook secret | Supabase and Worker secrets | Apps |
| Supabase URL and anon key | Apps (public by design, protected by RLS) | n/a |

### 5.4 Domains

| Host | Points to |
|---|---|
| Supabase project URL | Supabase (default URL; a custom domain is a paid add-on) |
| `cdn.yourdomain.com` | R2 public bucket |
| `track.yourdomain.com` | `tracking-gate` Worker |
| `admin.yourdomain.com`, `merchant.yourdomain.com` | Pages |

### 5.5 Versioning and compatibility

- RPC names end in `_v1`. A breaking change creates `_v2`; both run until old app versions are retired.
- Menu snapshots carry a `schema` number. Apps ignore unknown fields.
- WebSocket messages carry a `v` field.
- The minimum supported app version in Remote Config is the retirement mechanism.

---

## 6. Flows and data lifecycle

### 6.1 Browse and search
1. The app calls `get_merchant_feed_v1` (Supabase) and gets merchants with their `menu_version` and image paths.
2. Images load from `cdn.` (Cloudflare R2) and are cached on the device.
3. Opening a merchant downloads `menus/{id}/v{menu_version}.json` from the CDN, once per version.
4. Search calls `search_catalog_v1` (Supabase).

### 6.2 Place an order and notify (v1: cash or wallet)
1. The app calls `get_fee_preview_v1` (and `validate_promo_v1` if a code is used) as the cart changes.
2. The customer confirms. The app calls `place_order_v1`, which in one transaction re-prices the cart, checks hours and delivery zone, creates the order and its items, puts a ledger hold for wallet orders, and writes `order.placed`.
3. The dispatcher sends FCM to the branch staff and pushes into `BranchInbox`.
4. The merchant accepts through `transition_order_v1`. The event `order.accepted` triggers FCM to nearby drivers.
5. The first driver to tap calls `driver_claim_order_v1`, an atomic claim. Others see "already taken".
6. Status changes (`preparing`, `ready`, `picked_up`, `delivered`) each go through `transition_order_v1`, each writes an event, and each reaches the customer by FCM and by the live room.
7. On delivery: wallet orders capture the hold; cash orders write a `cash_collected` ledger entry so the daily driver settlement nets it out. Cancellations release or refund according to the fee rules.

### 6.3 Live tracking
1. When the order becomes `picked_up`, the driver app starts sending pings at the Remote Config interval.
2. The customer app opens the WebSocket (`tracking-gate` to `OrderRoom`), receives the current state, then live updates.
3. On `delivered` or `cancelled` the room closes, stores a route summary in Supabase once, and cleans itself up.
4. If the socket drops, the app reconnects and re-checks the status with Supabase.

### 6.4 Adding a payment gateway later (extension point, not built in v1)
Nothing in the order state machine, ledger or events changes. Add:
- a `payments` table (order, provider, provider reference, status, amounts) and a provider adapter interface (create payment, handle callback, refund);
- a Worker for the provider's callbacks (signature check, idempotency on the provider transaction id) that calls a `confirm_payment_v1` RPC;
- an Edge Function for create and refund calls (the only place an external call must happen inside a flow);
- a reconciliation job to catch missed callbacks;
- a Remote Config flag to turn the new payment method on gradually.

### 6.5 Menu and image updates
1. Staff edit a menu through an RPC. The same transaction bumps the merchant's `menu_version` and writes `menu.updated`.
2. The dispatcher calls `snapshot-builder`, which reads the menu through an RPC and writes `menus/{id}/v{n}.json`.
3. Apps see the new `menu_version` in the next feed response and fetch the new file.
4. Images: the app resizes on the device, asks `upload-signer` for a signed URL, uploads to R2, then saves the image path through an RPC.

### 6.6 Backup and archive

**Backup (interim, until Supabase Pro).** The nightly `export-jobs` Worker writes incremental exports of the critical tables to `private/backups/YYYY-MM-DD/`, kept 30 days. Test a restore before launch. This is a safety net, not a replacement for Supabase Pro's daily backups; a full `pg_dump` is better still and can run from any CI machine (outside these three services, so not specified here).

**Archive.** Orders older than 60 days (configurable) keep a slim row in Postgres (ids, totals, status, dates, `archive_key`). Their items and status history move to `private/archive/orders/YYYY/MM/{order_id}.json` and are deleted from Postgres. The app shows the summary and fetches details through a signed URL when the user opens an old order. This stretches the free database but does not remove the 500 MB limit (section 8).

---

## 7. Rules that must never break

1. Prices, fees and discounts are computed in Supabase at checkout, never trusted from an app, a snapshot or Remote Config.
2. Order status changes only through `transition_order`.
3. Every state change writes its `events` row in the same transaction.
4. Money is integer piastres and wallet changes are append-only ledger entries.
5. Cloudflare and Firebase never hold the only copy of anything.
6. Supabase Auth is the only login. Workers verify tokens; they never issue them.
7. Secrets exist only as Worker secrets or Supabase secrets, never in an app or in git.
8. Images and menus are served from R2 directly, never through Workers.
9. Durable Objects use hibernation only.
10. Every webhook and event consumer is idempotent.
11. Every external call (push, storage, future payments) sits behind an adapter so a provider can change without touching order logic.

---

## 8. Free-tier fit

**Assumptions (estimates, not measurements):** 1,500-2,000 daily active users, 2 sessions each per day; 1,000-2,000 orders/day; about 7 events per order; 3 tracking connections per order; driver pings every 15 seconds during a ~20-minute delivery; images 30-50 KB; 200 merchants and 20,000 items. The right-hand column is the High case.

| Service | Limit (Free) | Cap | Estimated use (High case) | Verdict |
|---|---|---|---|---|
| Supabase | Egress | 5 GB/month | ~1-1.5 GB | Fits |
| Supabase | Edge Function calls | 500K/month | ~0 (none used) | Fits |
| Supabase | Realtime | 200 conn, 2M msgs | ~0 (not used for tracking) | Fits |
| Supabase | Database size | 500 MB | Fills in ~80 days (High) or ~160 days (Low); archive stretches this to ~6 months at High | The one real wall |
| Cloudflare | R2 storage | 10 GB | 1-2 GB | Fits |
| Cloudflare | R2 read operations | 10M/month | 1.2-3.6M | Fits |
| Cloudflare | Workers requests | 100K/day (hard stop) | ~23K/day | ~4x headroom |
| Cloudflare | Durable Object requests | 100K/day | ~16K/day | ~6x headroom |
| Cloudflare | Durable Object rows written | 100K/day | ~40K/day | 2.5x headroom |
| Cloudflare | Durable Object duration | 13,000 GB-s/day | Small with hibernation | Fits |
| Firebase | FCM, Crashlytics, Analytics | No-cost | n/a | Fits |
| Firebase | Remote Config fetches | 100K/day | ~4K/day | Fits |

**Set an alert at 70% of every cap above.** The numbers above are modeled. If real traffic is 2-3 times higher, the order of the limits (database size first, then Workers requests) stays the same.

---

## 9. Scale ladder: when to pay and for what

| Signal | Next step | Cost |
|---|---|---|
| Database near 400 MB, or you need backups and no pausing (do this before real money) | Supabase Pro | $25/month; 8 GB disk then $0.125/GB; daily backups kept 7 days |
| CPU or RAM pressure, or connection errors | Larger Supabase compute | Small $15, Medium $60, Large $110 (dedicated 2 vCPU, 8 GB); Pro's $10 credit offsets one instance |
| Wallet balances need point-in-time recovery | PITR add-on | From $100/month per 7 days of retention |
| More than 100,000 monthly active users | Pro quota overage | $0.00325 per extra user |
| Workers approaching 100K requests/day | Workers Paid | $5/month minimum, no request cap |
| Durable Objects above the free allowance | Workers Paid | 1M requests and 400K GB-s included, then $0.15/M requests and $12.50/M GB-s |
| R2 above 10 GB | Pay as you go | $0.015/GB-month; $4.50/M writes; $0.36/M reads; egress stays free |
| Search quality complaints | Dedicated search engine | Not priced in this spec |

**Expected path:** $0 while building, about $25/month (Supabase Pro) at launch, and roughly $25-35/month once Workers Paid and a compute bump are added. Firebase stays free.

---

## 10. Rollout phases

| Phase | Build | Move on when |
|---|---|---|
| 1. Core | Supabase (all tables, Auth, RPC, cron, search); Firebase (FCM, Crashlytics, Analytics, Remote Config); Cloudflare R2 images, `upload-signer`, `outbox-dispatcher`, nightly export; Supabase Pro before real money | Orders flow end to end with push notifications and no crashes |
| 2. Speed | Menu snapshots, `snapshot-builder`, Pages dashboards for merchants and admin | Menu opens come from the CDN; merchants run on the web dashboard |
| 3. Live | Durable Objects: `OrderRoom`, `BranchInbox`, `tracking-gate`, driver pings | Customers see the driver moving; merchants get live orders |
| 4. Money (later) | Payment gateway through the extension point in section 6.4 | Online payment is required |

---

## 11. Open decisions

| Decision | Options | Default |
|---|---|---|
| Push tokens | Native FCM tokens (this spec) or the Expo push service (simpler, still free) | Native FCM |
| Domain | Needed for the CDN and tracking host | Buy one and put it on Cloudflare |
| R2 signup | Confirm whether a payment method is required to enable it | Check at signup |
| Supabase region | Choose the region closest to Cairo available in the dashboard | Check in the dashboard |
| PostGIS | Verify the extension is available; otherwise haversine in SQL | Use PostGIS if available |
| Cash handling | Rules for cash orders: limits per driver, settlement frequency | Daily settlement |
| Merchant channel | Merchants use the app, the web dashboard, or both | Web dashboard first, app later |
