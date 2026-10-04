# Open Questions — Spec 001

Unresolved items. This file exists so that undecided decisions stay visible instead of becoming
silent assumptions in code. **Adding a table, a fee rule or a payment path that is not answered here
is a bug in the spec, not initiative.**

Status: ⬜ open · 🟡 in progress · ✅ resolved (move to `decisions.md`)

---

## 1. Infrastructure

| # | Item | Status | Note |
|---|---|---|---|
| 1.1 | Supabase project `marketak` | ✅ | ref `erxxsebcqqcpkipzcdhg`, region `eu-central-1`, ACTIVE_HEALTHY, Postgres 17.11 |
| 1.2 | Supabase project_ref | ✅ | `erxxsebcqqcpkipzcdhg`. **Not yet written into the MCP URL** — see §1.7 |
| 1.3 | Firebase project | ✅ | `marketak-eg` (`marketak` was taken globally), number `283007295790` |
| 1.4 | R2 buckets | ✅ | `marketak-public` + `marketak-private`, `EEUR`. R2 enabled with a payment method |
| 1.5 | Cloudflare custom domain | ⬜ | Required for `cdn.`, `track.`, `admin.` and `vendor.` hosts. **Blocked on a domain purchase** — see §2.1 |
| 1.6 | ~~Does R2 require a payment method?~~ | ✅ | Yes. Set at enablement. ~$0/month at our volume |
| 1.7 | Scope the Supabase MCP | ⬜ | Unscoped it can touch every project in the account. Add `?project_ref=erxxsebcqqcpkipzcdhg` plus a read-only variant — recipe in `ENVIRONMENT.md` §4.3 |
| 1.8 | Android app package name | ✅ | `com.jaylak.mobile`. Note the root is `jaylak`, **not** the brand — the store listing is under your personal developer account |
| 1.9 | Register Android + iOS apps | ✅ | Android `…:android:e74edad733ca1550a55abf`, iOS `…:ios:6861ceffc5b2d0e3a55abf` |
| 1.10 | Android SHA-1 / SHA-256 | ⬜ | Add once the release signing cert exists. Not needed for FCM; needed for App Check |
| 1.11 | APNs key | ⬜ | **Blocked on an Apple Developer account.** Without it iOS gets no push at all |

---

## 2. Blocked on external accounts or purchases

| # | Item | Status | Note |
|---|---|---|---|
| 2.1 | Domain name | ⬜ | Needed for the CDN and the tracking host. A domain is the only unavoidable cash cost |
| 2.2 | Apple Developer account | ⬜ | iOS push through FCM requires an APNs authentication key uploaded to the Firebase console. Without it, iOS gets **no push notifications** |
| 2.3 | Production billing | ⬜ | Firebase is on the free Spark plan with no payment method. Adding one is optional |
| 2.4 | Mapping / geocoding provider | ⬜ | Location currently needs only latitude and longitude, so no provider is required yet. A free tier will not have a commercial SLA — acceptable while live tracking is off |

---

## 3. Product decisions not yet made

| # | Question | Status | Why it matters |
|---|---|---|---|
| 3.1 | What is the domain? | ⬜ | `cdn.<domain>`, `track.<domain>`, `admin.<domain>`, `merchant.<domain>` |
| 3.2 | Will `delivery_grouping = 'separate'` ever ship? | ⬜ | Modelled but not built. Deciding it now affects whether the fee formula needs a per-vendor branch |
| 3.3 | Vendor cancellation compensation rule | ⬜ | ADR 1 allows vendor rejection. Who absorbs the cost when a vendor cancels after `preparing`? Currently unspecified |
| 3.4 | Is `free_radius_km` measured from the vendor or the zone centroid? | ⬜ | Changes the fee for the same address depending on which vendor is ordered from. Zone centroid is simpler and fairer; vendor radius is more realistic |
| 3.5 | Does the rider `bonus_per_leg` exist at launch? | ⬜ | Rewards multi-vendor trips, which are harder. Costs margin on exactly the baskets the platform wants to encourage |
| 3.6 | Lunch capacity: what happens when a vendor is over `capacity_per_slot`? | ⬜ | Hide the vendor, or accept with a longer ETA? Affects revenue and customer trust differently |
| 3.7 | Should a partially-rejected order auto-remove the vendor, or always ask? | ⬜ | Auto-removing loses basket value silently. Always asking adds friction at the worst moment |
| 3.8 | Minimum order across the whole cart, or per vendor only? | ⬜ | Per-vendor only is implemented. A cart-wide minimum would raise the average basket but add a failure mode |

---

## 4. Unverified assumptions

Each of these is modelled, not measured. Re-check before trusting any of them for a quarter.

| # | Assumption | Verify by |
|---|---|---|
| 4.1 | Row and index sizes within 2× of the model | `pg_total_relation_size` after 1,000 real orders |
| 4.2 | Free-plan CPU survives a lunch peak | Load test 100 concurrent `place_order_v1` through the peak window |
| 4.3 | 2.9 KB/order after archiving holds | Same as 4.1 |
| 4.4 | PostGIS availability on `eu-central-1` | ✅ **Resolved.** Available, 3.3.7. The design still uses geohash and does not need it |
| 4.5 | DO memory bills at 128 MB for SQLite-backed objects | Dashboard, before enabling tracking |
| 4.6 | Frankfurt latency acceptable against a 900 ms p95 | Measure. **If it fails, migrate regions early — it is not a toggle** |

---

## 5. Explicitly deferred, not decided

Recorded so they are not mistaken for oversights.

| # | Item | When it returns |
|---|---|---|
| 5.1 | Live rider tracking | Phase 8, flag default off. Affordable at ~500 orders/day, unaffordable at 2,000 |
| 5.2 | Payment gateway integration | Extension point in `plan.md` §8. Adds a third `payment_channel`; does not replace cash or direct transfer |
| 5.3 | Loyalty / subscriptions | Not specced |
| 5.4 | Scheduled / recurring delivery | Not specced |
| 5.5 | Split delivery to multiple addresses | Explicitly rejected; one checkout is one address |
| 5.6 | Multi-branch vendors | Rejected for v1. A chain is N vendors sharing a `brand_id` |
| 5.7 | Ads / banner revenue | Slots modelled, unsold |
| 5.8 | Push funding | Not an option in v1. Notifications are transactional only |

---

## 6. Known gaps in this spec

| # | Gap | Impact |
|---|---|---|
| 6.1 | **No migration `.sql` files exist.** The DDL lives as fenced blocks in `data-model.md`, ordered by its §14 | Task **T0.1a** extracts them. An agent must not write migrations by hand and drift from the spec |
| 6.2 | No seed data script | T0.9 |
| 6.3 | No `.gitignore` | Must exist before the first commit |
| 6.4 | No CI | pgTAP policy tests in migration 022 are meant to fail the build; nothing runs them yet |
| 6.5 | No human review of this spec | It is authored, not approved. Treat every number as a proposal |
| 6.6 | RLS policies are described, not written | Migration 014 |
| 6.7 | RPC bodies are not written | Migrations 016–020 |
| 6.8 | `vendors.reject_rate` and `audit_log` are in the schema with no stated use | Remove or specify |