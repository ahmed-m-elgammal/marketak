# Marketak · ماركتك — Mobile UI/UX Blueprint

HTML-only design blueprint for the **one React Native app** (Customer + Rider, role-switched).
Built strictly UI/UX-first: every screen is grounded in `specs/001-platform-foundation` and the
live database schema — field names, error codes, states and actions come from the specs, not
from imagination.

**Open `design/index.html` first** — it is the gallery that links everything with live previews.

## Layout

| Path | What it holds |
|---|---|
| `tokens/tokens.css` | **Single source of truth.** Mirrors `packages/ui/src/theme/` verbatim (brand `#B54708`, chrome `#1C1917`, IBM Plex Sans Arabic, 4px spacing, 48px touch) + mobile type scale + component layer + 3 theme skins. Screens hardcode nothing. |
| `assets/icons.js` | The 56-glyph SVG icon sprite (single source, file://-safe injector) incl. the generated Marketak mark, official Google/Apple plates, Vodafone Cash/Instapay glyphs. |
| `assets/blueprint.css` | Documentation chrome only: phone frame (393×852), status bar, annotation panels. |
| `system.html` | Design system: colour tokens + contrast, type scale (bilingual rules), spacing/radius/elevation/motion, icons, components with all states, interaction patterns derived from the constitution. |
| `experience.html` | **The Zero-Think experience doctrine** — the 8 industry rules we break, 8 counter-moves each grounded in a real engine constraint, 6 zero-think principles with acceptance tests, 4 signature rituals, the Egyptian voice table (robot vs Marketak copy), and the 8-question checklist that gates every future screen. Behaviour layer that sits **above** any skin. |
| `experience-demos.html` | The doctrine applied: three live phone mockups from one real day (12:15 “نفس طلب امبارح؟” zero home → 12:16 the Tray confirm with everything pre-decided → 1:02 “الصاحب جاي عليك” sentence tracking) + before/after table + touch-count metrics (2 taps, 0 payment screens, 1 sentence). |
| `architecture.html` | Launch/auth flow (`get_profile_status_v1` branches), customer & rider tab maps, order + trip state machines, full screen inventory in 6 batches, push-notification → screen routing. |
| `screens/…` | Screen blueprints. Each page = live phone mockup + spec annotations + mandatory edge states. |
| `index.html` | Gallery with live previews of everything. |

## Batch 1 (this commit) — 3 screens × 3 design directions

| Screen | A · Warm Minimal | B · Midnight Chrome | C · Fresh Editorial |
|---|---|---|---|
| 01 Sign In (Google/Apple only) | `screens/01-sign-in/a-warm-minimal.html` | `…/b-midnight-chrome.html` | `…/c-fresh-editorial.html` |
| 02 Profile Completion gate | `screens/02-profile-completion/a-warm-minimal.html` | `…/b-midnight-chrome.html` | `…/c-fresh-editorial.html` |
| 03 Customer Home | `screens/03-customer-home/a-warm-minimal.html` | `…/b-midnight-chrome.html` | `…/c-fresh-editorial.html` |

The three directions share one token core — picking one means picking a *skin*
(`.theme-a/.theme-b/.theme-c`), not a rebuild. **The skin decides how it looks; the doctrine
(`experience.html`) decides how it behaves** — the skins stay valid and every batch-2+ screen is
designed through the doctrine (batch-1 home A is kept as the “industry baseline” we measure against).
Next batches (see `architecture.html` §5): vendor/menu → cart/quote → payment & tracking →
orders & settings → rider surfaces → earnings — vendor detail becomes a “lunch decision”, not a catalogue.

## Non-negotiables carried from the repo

- **Auth:** Google + Apple only (no email/password/OTP). Apple first on iOS.
- **Gate:** browse always allowed; ordering blocked until `missing[]` = first/last/phone/address is complete (`complete_profile_v1`).
- **Money:** display-only, always with currency (`25.00 ج.م`), server-priced; `PRICE_CHANGED`/quote-TTL patterns designed, nothing computed client-side.
- **No customer wallet** (ADR 2) — cash / Vodafone Cash / Instapay **at delivery**.
- **Status is word + colour, never colour alone; no uppercase; no letter-spacing on Arabic** (Arabic-first, RTL default, logical properties throughout).
- **Every screen designed with loading / empty / error / offline states** before being called done.
- **Zero-Think gate (new):** every screen from batch 2 on must pass the 8-question checklist in `experience.html` §6 — one decision per screen, smart defaults, zero typed characters in the main ordering path, human Egyptian copy via the voice table (§5).

## Assets

All imagery (logo, illustrations, map, food art) is **generated SVG** in the project's own
illustration palette (`--mk-illu-*`) — no external/stock dependencies, appropriate for the
Egypt-first launch.

## How to review

1. Open `index.html` (or serve the folder statically).
2. Pick a direction per screen (A/B/C) — or mix: the token system supports it.
3. Read each screen's annotation panel: it cites the RPCs, error codes and schema fields the screen consumes.
