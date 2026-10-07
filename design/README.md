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
(`.theme-a/.theme-b/.theme-c`), not a rebuild. Next batches (see `architecture.html` §5):
vendor/menu → cart/quote → payment & tracking → orders & settings → rider surfaces → earnings.

## Non-negotiables carried from the repo

- **Auth:** Google + Apple only (no email/password/OTP). Apple first on iOS.
- **Gate:** browse always allowed; ordering blocked until `missing[]` = first/last/phone/address is complete (`complete_profile_v1`).
- **Money:** display-only, always with currency (`25.00 ج.م`), server-priced; `PRICE_CHANGED`/quote-TTL patterns designed, nothing computed client-side.
- **No customer wallet** (ADR 2) — cash / Vodafone Cash / Instapay **at delivery**.
- **Status is word + colour, never colour alone; no uppercase; no letter-spacing on Arabic** (Arabic-first, RTL default, logical properties throughout).
- **Every screen designed with loading / empty / error / offline states** before being called done.

## Assets

All imagery (logo, illustrations, map, food art) is **generated SVG** in the project's own
illustration palette (`--mk-illu-*`) — no external/stock dependencies, appropriate for the
Egypt-first launch.

## How to review

1. Open `index.html` (or serve the folder statically).
2. Pick a direction per screen (A/B/C) — or mix: the token system supports it.
3. Read each screen's annotation panel: it cites the RPCs, error codes and schema fields the screen consumes.
