# Marketak Mobile App --- Design System & Product UI Specification

**Status:** Source of truth for mobile UI/UX\
**Platform:** React Native + Expo\
**Product:** Multi-merchant delivery marketplace (restaurants, grocery,
bakery, pharmacy, supermarkets, and other local shops)\
**Brand direction:** Premium, calm, confident, practical, locally
relevant --- not childish and not a clone of another delivery app.

------------------------------------------------------------------------

## 1. Purpose and rules

This document defines the visual system, interaction patterns, screen
requirements, loading and error behavior, accessibility, and
implementation rules for Marketak's customer/driver mobile app.

### Non-negotiable rules

1.  **Use this file as the single design source of truth.** Do not
    invent new colors, spacing, typography, components, or navigation
    patterns without updating this document first.
2.  **Reuse existing project structure and components.** Do not create
    new folders or parallel systems just because a screen needs a
    component. Check the repository architecture before adding files.
3.  **Keep presentation separate from business logic.** Screens render
    state; hooks/services own data fetching and mutations.
4.  **Every interactive state must be designed:** default, loading,
    empty, error, disabled, success, offline, and permission-denied
    where applicable.
5.  **Never show a dead end.** Every error or empty state should explain
    what happened and offer a relevant next step.
6.  **Do not use fake data in production UI.** Clearly label demo/seed
    data in development and review builds.
7.  **No emoji as production icons.** Use the project's chosen icon
    library consistently.
8.  **No arbitrary gradients, glassmorphism, excessive shadows, floating
    cards, or decorative blobs.** Use them only if explicitly approved.
9.  **Do not imitate Talabat or other competitors.** Marketak should
    feel like a curated local marketplace, not a generic food-delivery
    template.
10. **RTL and Arabic are first-class.** Every layout must work in Arabic
    and English, including mixed Arabic/Latin content.

------------------------------------------------------------------------

## 2. Brand and visual identity

### Brand attributes

-   **Trustworthy:** particularly important for pharmacy, groceries,
    payments, and order tracking.
-   **Efficient:** clear hierarchy and fast task completion.
-   **Local:** accommodates Egyptian addresses, phone numbers, currency,
    and Arabic.
-   **Premium but approachable:** restrained design, real merchant
    photography, crisp typography.
-   **Marketplace-first:** the identity covers all merchant types, not
    food alone.

### Core palette

Use semantic tokens rather than hard-coded hex values in components.

  ------------------------------------------------------------------------
  Token                    Hex                     Use
  ------------------------ ----------------------- -----------------------
  `brand.primary`          `#123F35`               Main brand green;
                                                   primary buttons,
                                                   selected states, key
                                                   brand elements

  `brand.primaryPressed`   `#0D3029`               Pressed primary
                                                   controls

  `brand.primarySoft`      `#E5EEE9`               Selected backgrounds,
                                                   subtle brand surfaces

  `brand.cream`            `#F8F5EE`               Main warm background /
                                                   brand canvas

  `surface.default`        `#FFFFFF`               Main cards, sheets,
                                                   inputs

  `surface.subtle`         `#F4F2EC`               Secondary panels and
                                                   grouped sections

  `text.primary`           `#17211E`               Main text

  `text.secondary`         `#66716C`               Supporting text

  `text.tertiary`          `#89928D`               Hints and low-priority
                                                   metadata; verify
                                                   contrast

  `border.default`         `#E2E5E0`               Dividers, outlines

  `border.strong`          `#B8C2BB`               Stronger outlines and
                                                   input boundaries

  `status.success`         `#24734E`               Success indicators

  `status.warning`         `#946116`               Warnings and
                                                   time-sensitive notices

  `status.error`           `#B42318`               Errors and destructive
                                                   actions

  `status.info`            `#245C87`               Informational states

  `overlay.scrim`          `#17211E` at 48%        Modal and sheet
                           opacity                 backdrop
  ------------------------------------------------------------------------

**Palette rules** - Forest green is the main brand color. Do not default
to bright orange. - Cream is a supporting background, not a reason to
put every screen on a tinted canvas. - Use white surfaces for dense
commerce screens to keep prices and product images clear. -
Category-specific colors may appear in photography or small accents, but
must not replace the brand palette. - Status colors communicate meaning,
never decoration. - Check actual contrast ratios before release. Do not
rely on color alone to communicate status.

### Logo use

-   Use the approved Marketak geometric "M" mark for the app icon.
-   Use the approved bilingual wordmark where space permits.
-   Never recreate the logo with typed text or approximate it with a
    generic icon.
-   Keep sufficient clear space around the logo; do not stretch, rotate,
    add effects, or recolor it outside approved variants.
-   App icon artwork must be exported as a square source asset. Let
    iOS/Android apply platform masking; do not bake a rounded mask into
    every exported variant unless the platform asset specification
    requires it.
-   Keep a monochrome logo variant for small or constrained contexts.

------------------------------------------------------------------------

## 3. Typography

Use the project's licensed, bundled fonts. If no font has been selected,
use a clean modern sans-serif with reliable Arabic glyph coverage;
validate Arabic shaping on real devices before finalizing. Avoid mixing
unrelated font families.

Suggested type tokens:

  Token            Size Weight     Typical use
  -------------- ------ ---------- -------------------------------------
  `display`          32 Bold       Rare hero title
  `h1`               28 Bold       Screen title when prominent
  `h2`               22 Semibold   Section title
  `h3`               18 Semibold   Card or subsection title
  `body`             16 Regular    Main content
  `bodyMedium`       16 Medium     Emphasized body content
  `bodySmall`        14 Regular    Secondary content
  `label`            13 Medium     Labels, metadata
  `caption`          12 Regular    Timestamps and low-priority details
  `button`           16 Semibold   Button labels
  `price`            18 Bold       Primary price
  `priceSmall`       14 Semibold   Compact price

Rules: - Use a consistent type scale; do not choose arbitrary font sizes
per screen. - Prices must be easy to scan and visually distinct from
descriptions. - Do not use all-caps for ordinary labels. - Avoid long
text blocks in commerce cards. - Allow system font scaling. Layouts must
not clip when text is enlarged. - Arabic and English may need different
font metrics; align by visual baseline, not assumptions. - Format
currency, dates, phone numbers, and numerals through shared locale-aware
utilities.

------------------------------------------------------------------------

## 4. Layout, spacing, and shape

### Spacing scale

Use a 4-point base grid:

  Token          Value
  ------------ -------
  `space.1`          4
  `space.2`          8
  `space.3`         12
  `space.4`         16
  `space.5`         20
  `space.6`         24
  `space.8`         32
  `space.10`        40
  `space.12`        48
  `space.16`        64

Rules: - Screen horizontal padding: usually 16--20. - Separate major
sections by 24--32. - Keep at least 8 between related controls. - Use
safe-area insets and keyboard insets; never position important content
behind system UI. - Prefer scrolling layouts over compressed layouts. -
Use consistent content alignment within a screen.

### Radius tokens

  Token             Value Use
  --------------- ------- ----------------------------------
  `radius.sm`           8 Small chips, compact controls
  `radius.md`          12 Inputs, small cards
  `radius.lg`          16 Product and merchant cards
  `radius.xl`          24 Bottom sheets and major panels
  `radius.pill`       999 Pills and fully rounded controls

Do not round every container identically. Use radius to express
component hierarchy.

### Elevation and borders

-   Default cards: flat surface with a subtle border.
-   Use shadows sparingly for overlays, floating controls, and sheets.
-   Never use heavy shadows to compensate for weak hierarchy.
-   Separate sections using spacing before adding dividers.
-   Interactive elements must have clear pressed and focus states.

### Grid and image ratios

-   Merchant hero/cover images: typically 16:9 or 3:2.
-   Product images: square 1:1.
-   Category thumbnails: square or consistent landscape crops.
-   Keep image containers stable to prevent layout jumps.
-   Use real merchant/product photography where available; avoid
    inconsistent stock art.
-   Define fallback imagery for missing, broken, or slow-loading images.

------------------------------------------------------------------------

## 5. Iconography and imagery

-   Use one consistent icon set already installed in the repository. Do
    not add another library without approval.
-   Icons should be simple, legible, and optically consistent.
-   Standard icon sizes: 16, 20, 24; use 28--32 only for prominent empty
    states or hero actions.
-   Pair unfamiliar icons with labels.
-   Do not use icon-only buttons unless the icon is universally
    understood and the button has an accessibility label.
-   Product and merchant photography must be appropriately cropped and
    compressed.
-   Never stretch images or display broken-image placeholders.
-   Loading image placeholders should preserve the final image
    dimensions.

------------------------------------------------------------------------

## 6. Component specifications

Build or reuse shared components where they already belong in the
project architecture. Do not duplicate components across features.

### Buttons

Variants: - **Primary:** forest-green fill, white label. -
**Secondary:** soft green or neutral fill with dark label. -
**Outline:** transparent/white surface, border, dark label. - **Text:**
no container, clear text action. - **Destructive:** error color, used
only for destructive actions.

States: - Default, pressed, focused, disabled, loading. - Loading
buttons must prevent duplicate submissions and keep a stable width. -
Disabled controls need a visible disabled treatment and a clear reason
when the reason is not obvious. - Touch target: aim for at least 44×44
pt on iOS and 48×48 dp on Android. - Button text must describe the
action: "Place order", "Save address", "Try again"; avoid vague "OK"
where possible.

### Inputs

-   Always provide a visible label or an equivalent accessible label.
-   Placeholder text is an example, not a replacement for the label.
-   Show inline validation near the relevant field.
-   Preserve valid input after recoverable errors.
-   Use appropriate keyboards and input modes for email, phone,
    quantity, search, and numeric values.
-   Support paste, autofill, and password-manager behavior where
    relevant.
-   Do not clear a form because one field failed validation.
-   Show password visibility control when useful; announce its state
    accessibly.

### Cards

-   Merchant cards: image, merchant name, category or key
    differentiator, delivery estimate when available, fee/minimum only
    when relevant, and open/closed status.
-   Product cards: image, product name, unit/size where needed, price,
    discount only when valid, and add action.
-   Do not overload cards with every possible metric.
-   Avoid putting nested buttons inside another clickable card unless
    interaction and accessibility are handled correctly.

### Chips and filters

-   Use chips for compact selectable filters and categories.
-   Clearly distinguish selected, unselected, disabled, and loading
    states.
-   Make selected filters removable or easy to reset.
-   Show active filter count when useful.
-   Do not hide important filter state after navigation.

### Bottom sheets and dialogs

-   Use a bottom sheet for contextual, lightweight choices.
-   Use a dialog for critical confirmation or short blocking decisions.
-   Keep titles and primary actions visible above the keyboard where
    possible.
-   Dismiss on backdrop tap only when safe; never discard important
    unsaved work silently.
-   Destructive actions require clear consequence text and an explicit
    cancel option.

### Toasts and banners

-   Toasts: brief, non-critical feedback such as "Address saved".
-   Banners: persistent or actionable issues such as an unavailable
    service area.
-   Do not use a toast for errors requiring user action.
-   Avoid stacking multiple toasts.
-   Screen readers must be able to perceive important status messages.

### Navigation bars

-   Use a consistent navigation pattern across the customer experience.
-   Keep labels clear and icons consistent.
-   Preserve expected navigation state when returning from details.
-   Hide or adapt bottom navigation on flows where it would interfere,
    such as checkout or full-screen tracking.
-   Do not create a new navigation pattern for each feature.

------------------------------------------------------------------------

## 7. App architecture and implementation contract

The UI system must fit the existing repository architecture. Before
implementing, inspect the current folder structure, routing, shared
components, data hooks, and styling approach.

### Layer responsibilities

-   **Routes/screens:** compose components and connect feature state;
    keep route files thin.
-   **Feature UI/components:** render domain-specific interface.
-   **Shared UI:** reusable, domain-neutral primitives.
-   **Hooks/state:** manage view state and coordinate use cases.
-   **Services/repositories:** perform network and persistence
    operations.
-   **Domain/types:** define business entities and status types.
-   **Theme/tokens:** define all visual constants in one place.
-   **Localization:** own user-facing strings and locale formatting.

Do not place database queries, payment logic, delivery calculations, or
complex business rules directly in visual components.

### Code rules

-   Follow existing naming conventions and established file-size limits.
-   Reuse the current query/cache library and existing typed API layer.
-   Avoid duplicate requests, duplicate mutation submissions, and
    unnecessary rerenders.
-   Never hard-code secrets, API keys, merchant IDs, or user-specific
    data in the client.
-   Use typed response and error models.
-   Keep UI states explicit; avoid many unrelated booleans that can
    produce impossible combinations.
-   Add dependencies only when necessary and compatible with the current
    Expo/React Native versions.
-   Avoid web-only APIs in native code.
-   Do not reorganize the repository or create folders outside the
    agreed architecture without approval.

------------------------------------------------------------------------

## 8. Localization, Arabic, and RTL

Arabic is a primary product language, not a translated afterthought.

-   Support English LTR and Arabic RTL throughout the app.
-   Use the established localization library and message keys; never
    scatter inline translations.
-   Use logical start/end spacing rather than left/right assumptions.
-   Mirror directional icons where meaning requires it; do not mirror
    brand marks, logos, or non-directional icons.
-   Verify back navigation, chevrons, carousels, progress indicators,
    maps, and swipe actions in RTL.
-   Keep phone numbers, email addresses, URLs, order IDs, and Latin
    product codes readable in RTL layouts.
-   Use locale-aware formatting for currency and dates.
-   For Egypt, display EGP using the project's consistent currency
    formatter. Do not hard-code currency formatting inside individual
    components.
-   Avoid concatenating translated fragments; use complete localized
    messages with interpolation.
-   Allow text to wrap naturally. Do not assume English string lengths.
-   Test long merchant names, Arabic names, mixed scripts, and larger
    text sizes on physical devices.

------------------------------------------------------------------------

## 9. Accessibility

Target WCAG 2.2 AA principles where applicable to the mobile interface
and follow platform accessibility conventions.

-   Maintain sufficient text and non-text contrast.
-   Never communicate state using color alone.
-   Give every interactive element a meaningful accessible name and
    role.
-   Ensure screen-reader order follows the visual reading order,
    including RTL.
-   Announce loading completion, validation errors, and important
    order-status changes without overwhelming the user.
-   Support Dynamic Type/font scaling.
-   Respect reduced-motion preferences.
-   Avoid flashing, unnecessary parallax, and motion that blocks task
    completion.
-   Provide accessible labels for icon-only buttons, quantity controls,
    ratings, and status indicators.
-   Do not make a tiny visual icon the only touch target.
-   Test with VoiceOver and TalkBack before release.

------------------------------------------------------------------------

## 10. Motion and feedback

Motion should clarify cause and effect, not decorate the interface.

-   Typical micro-interaction duration: 120--220 ms.
-   Use consistent easing and avoid springy, playful animations.
-   Animate add-to-cart feedback, sheet transitions, selection changes,
    and status changes only when useful.
-   Never delay a critical action for an animation.
-   Respect reduced-motion settings.
-   Use skeletons only when the layout is known and loading lasts long
    enough to benefit.
-   Avoid showing skeletons for very short waits; prevent flicker.
-   Preserve scroll position and image dimensions when content
    refreshes.

------------------------------------------------------------------------

## 11. Screen design requirements

Every screen must define: purpose, entry points, content hierarchy,
primary action, secondary actions, loading state, empty state, error
state, disabled state, accessibility labels, analytics events where
appropriate, and RTL behavior.

### Authentication

-   Sign in, sign up, password reset, verification, and session-expired
    states.
-   Support the authentication methods actually enabled by the backend.
-   Validate fields inline and preserve form values after recoverable
    failures.
-   Explain whether verification is required and what happens next.
-   Provide clear recovery from expired codes, wrong credentials,
    network failures, and rate limits.
-   Never reveal whether an account exists when that would create a
    security/privacy issue; follow backend policy.

### Home and discovery

-   Show the selected delivery location clearly.
-   Make merchant categories discoverable without overwhelming the
    screen.
-   Prioritize useful nearby/relevant merchants, active promotions, and
    recent activity only when data exists.
-   Avoid excessive carousels and stacked promotional banners.
-   Provide a clear search entry point.
-   If location is unavailable, allow manual address selection instead
    of blocking the whole screen.

### Search

-   Provide recent searches, useful suggestions, filters, and clear
    reset behavior.
-   Debounce requests and cancel or ignore stale responses.
-   Distinguish no query, searching, no results, request failure, and
    offline state.
-   Preserve the query when opening a result and returning.
-   Do not show "no results" while the request is still loading.

### Categories and merchant listing

-   Make active category/filter state obvious.
-   Display accurate delivery estimates and availability only when
    supplied by the service.
-   Mark closed, paused, or out-of-service merchants clearly.
-   Explain why a merchant cannot be ordered from when that information
    is available.
-   Avoid presenting estimates as guarantees.

### Merchant details and catalog

-   Show merchant name, status, delivery information, relevant fees, and
    catalog sections.
-   Keep product names, sizes, options, and prices readable.
-   Clearly identify required versus optional modifiers.
-   Handle sold-out products, changing prices, unavailable options, and
    merchant closure.
-   Do not allow adding an invalid configuration to the cart.
-   Preserve the user's scroll position when returning from a product.

### Product details

-   Show image, name, price, size/unit, description, availability, and
    required options.
-   Update price when options or quantity change.
-   Disable add-to-cart when required options are missing.
-   Explain unavailable options and offer valid alternatives when
    available.
-   Avoid silently changing the user's selection.

### Cart

-   Clearly show merchant, items, quantity, options, subtotal, fees,
    discounts, delivery fee, and total.
-   Recalculate totals using trusted backend values at checkout.
-   Communicate minimum order requirements and unavailable items.
-   Confirm removal only when accidental loss is likely; allow easy undo
    when safe.
-   Explain multi-merchant cart restrictions. If the system supports one
    merchant per order, make the behavior clear before the user loses
    items.
-   Do not treat client-calculated totals as authoritative.

### Checkout

-   Require confirmation of delivery address, contact details, delivery
    method/time if supported, payment method, discount code, and order
    total.
-   Make all extra fees visible before final submission.
-   Prevent duplicate order creation while a request is pending.
-   If order submission times out, check order status before retrying to
    avoid duplicate orders.
-   Do not claim an order succeeded until the backend confirms it.
-   If price or availability changed, show a review step before the
    final purchase.
-   Keep a clear path to edit address or cart contents.

### Payments and discounts

-   Show only payment methods actually enabled for the user/order.
-   Handle declined, cancelled, pending, timed-out, and unknown payment
    states distinctly.
-   Never ask users to share card PINs, OTPs, or wallet credentials in
    support chat.
-   Apply promo codes with clear success, invalid, expired,
    minimum-spend, usage-limit, and eligibility messages.
-   Recalculate discounts and totals on the server.
-   Never display a discount as applied until the backend confirms it.

### Order confirmation and tracking

-   Show confirmed order number, merchant, total, delivery address, and
    current status.
-   Use a clear status timeline with plain-language labels.
-   Distinguish confirmed, accepted, preparing, ready for pickup, picked
    up, on the way, delivered, cancelled, and issue states according to
    the actual backend model.
-   Do not invent driver location or ETA when live data is missing.
-   If live tracking disconnects, show the last update time and retry
    status.
-   Provide support/contact options when appropriate.
-   Order status must remain correct after app restart or navigation.

### Order history and reorder

-   Provide useful status, date, merchant, and total information.
-   Reorder must revalidate availability, current prices, options, and
    merchant status.
-   Explain items that are no longer available instead of silently
    dropping them.
-   Distinguish cancelled and failed orders from completed orders.

### Favorites

-   Provide clear add/remove feedback and a useful empty state.
-   Handle deleted, closed, or unavailable merchants.
-   Keep favorite state consistent across screens after successful
    server updates.

### Address management

-   Support saved addresses, map pin selection where available, and
    manual address entry.
-   Collect useful delivery details such as building, floor, apartment,
    landmark, and recipient phone where appropriate.
-   Validate service coverage before promising delivery.
-   Explain denied location permission and offer manual entry.
-   Do not overwrite a saved address without explicit confirmation.
-   Show which address is currently selected.

### Notifications

-   Ask for notification permission in context, after explaining the
    benefit.
-   The app must still work when permission is denied.
-   Provide an in-app order-status fallback.
-   Handle tapping a notification when the app is cold-started,
    backgrounded, or already open.
-   Validate notification payloads and route safely when referenced
    content is unavailable.

### Profile and settings

-   Provide account details, saved addresses, language, notification
    preferences, support, legal documents, and sign out as applicable.
-   Confirm destructive account actions and explain consequences.
-   Handle session expiry consistently.
-   Do not expose private account data in logs or analytics.

### Driver experience (if included in the same app)

-   Separate customer and driver modes clearly; never mix their
    navigation or data accidentally.
-   Show driver availability, active assignment, pickup/drop-off
    instructions, and delivery completion state.
-   Location permission and background-location requirements must be
    explained before requesting access.
-   Show stale GPS/location status honestly.
-   Prevent accidental completion or cancellation with appropriate
    confirmation.
-   Ensure driver actions are idempotent or protected against duplicate
    submissions.
-   Never expose one customer's address or contact information to
    another customer.

------------------------------------------------------------------------

## 12. Universal loading, empty, error, and offline states

Every data-driven feature must define these states.

### Loading

-   Use a skeleton that matches the final layout for initial page loads
    where useful.
-   Use a small inline indicator for refreshes and button-level
    operations.
-   Keep existing content visible during background refresh when safe.
-   Do not replace the whole screen with a spinner for every mutation.
-   Prevent repeated taps while an operation is pending.

### Empty

An empty state must include: 1. A clear title. 2. A short explanation.
3. One relevant next action when possible.

Examples: - No favorites: "Your saved places will appear here." Action:
"Explore merchants". - Empty cart: "Your cart is waiting for something
good." Action: "Browse merchants". - No orders: "Your orders will appear
here." Action: "Explore Marketak". - No search results: "No matches
found." Action: "Clear filters" or "Try another search".

Do not use empty states to disguise API failures.

### Error

Each error must have: - A user-friendly message. - A clear recovery
action when possible. - A safe fallback if recovery is impossible. - A
diagnostic identifier for support only when useful. - Logging/monitoring
that excludes secrets and sensitive personal data.

Do not show raw stack traces, database errors, SQL messages, internal
endpoint details, or provider error payloads to users.

### Offline

-   Detect connectivity where supported, but treat it as a hint rather
    than proof that the backend is reachable.
-   Show a compact offline banner when it affects the task.
-   Keep safe cached content available where appropriate.
-   Disable actions that cannot work offline and explain why.
-   Queue mutations only when the product explicitly supports safe
    queuing.
-   Never queue order placement or payment submission blindly.
-   Retry reads with backoff; avoid aggressive retry loops.
-   Show when displayed content may be stale.

### Refresh and stale data

-   Pull-to-refresh must provide visible feedback.
-   Avoid clearing valid content before a refresh succeeds.
-   Indicate stale information where it affects prices, availability,
    delivery status, or safety.
-   Revalidate important data before checkout and order submission.

------------------------------------------------------------------------

## 13. Error handling contract

Use a typed, centralized error model. Map backend/provider failures to
stable application error codes and localized user messages.

### Error categories

  -----------------------------------------------------------------------
  Category                            UI behavior
  ----------------------------------- -----------------------------------
  Validation                          Inline message next to the relevant
                                      field

  Authentication/session              Explain session issue; offer
                                      sign-in/refresh

  Permission denied                   Explain why permission helps; offer
                                      settings or manual fallback

  Network/offline                     Preserve user input; offer retry

  Timeout/unknown result              Check server state before allowing
                                      a repeat mutation

  Rate limited                        Explain briefly and respect retry
                                      timing

  Not found/deleted                   Explain content is unavailable;
                                      offer navigation back

  Conflict/stale data                 Refresh affected content and ask
                                      user to review changes

  Unavailable merchant/item           Mark unavailable; offer
                                      alternatives

  Payment failure                     State payment status clearly; avoid
                                      duplicate charges

  Server failure                      Generic message, retry when safe,
                                      log diagnostic details

  Unexpected client failure           Safe fallback/error boundary;
                                      provide recovery path
  -----------------------------------------------------------------------

### Mutation safety

-   Disable repeat submission while pending.
-   Use idempotency keys for order/payment mutations where supported by
    the backend.
-   A timeout does **not** prove a mutation failed.
-   For unknown order/payment outcomes, query authoritative status
    before offering a retry.
-   Keep optimistic updates reversible and use them only where the
    result is safe to predict.
-   Roll back failed optimistic updates and tell the user what changed.
-   Never swallow errors silently.

### Error boundaries

-   Use an app-level error boundary and feature-level boundaries where
    appropriate.
-   A recoverable screen error should not crash the whole app.
-   Provide "Try again" only if retrying can reasonably help.
-   Capture crash/error reports with app version, platform, route, and
    sanitized diagnostic context.
-   Never send passwords, access tokens, full payment details, or
    unnecessary personal data to logs/analytics.

### Retry policy

-   Retry transient read requests with bounded exponential backoff and
    jitter.
-   Respect server-provided retry timing.
-   Do not automatically retry non-idempotent order or payment mutations
    unless the backend guarantees safety.
-   Stop retries when the user leaves the flow or the request is no
    longer relevant.
-   Avoid repeated alerts for the same failure.

------------------------------------------------------------------------

## 14. Permissions and privacy

-   Ask for location, notifications, camera, or other permissions only
    when the user reaches a feature that needs them.
-   Explain the benefit before the operating-system prompt.
-   Provide a usable alternative when permission is declined.
-   Do not request permissions "just in case".
-   Avoid collecting or displaying more personal information than the
    task requires.
-   Mask sensitive information in logs and support diagnostics.
-   Use secure storage for credentials and tokens; never plain-text
    storage.
-   Clear user-specific cached state on sign-out where required.
-   Prevent private data from appearing in app-switcher snapshots when
    the platform and threat model require it.
-   Follow applicable privacy policy, retention, and deletion
    requirements.

------------------------------------------------------------------------

## 15. Performance and reliability

-   Prioritize fast perceived startup and responsive navigation.
-   Load lists incrementally; paginate or virtualize long catalogs and
    order histories.
-   Resize and compress remote images appropriately.
-   Cache stable read data according to its freshness requirements.
-   Avoid unnecessary refetching and duplicate network calls.
-   Cancel obsolete searches and ignore stale responses.
-   Keep animations smooth on mid-range Android devices.
-   Do not block the JS/UI thread with expensive transformations.
-   Avoid layout shifts during image loading.
-   Test on physical Android devices and iOS simulators/devices
    available to the team.
-   Treat poor network conditions as a normal scenario, not an edge
    case.

------------------------------------------------------------------------

## 16. Security and trust in UI

-   The client is not authoritative for prices, discounts, permissions,
    delivery eligibility, payment status, or order state.
-   Display only data the current user is authorized to access.
-   Avoid revealing internal IDs unless they help support or order
    lookup.
-   Never put secrets in client code or logs.
-   Sanitize untrusted text before rendering rich content.
-   Confirm consequential actions such as cancellation when appropriate.
-   Explain irreversible actions before they occur.
-   Do not imply a pharmacy product is medically recommended or
    clinically verified unless the product's compliance and content
    rules support that claim.

------------------------------------------------------------------------

## 17. Analytics and observability

Track meaningful product events without collecting unnecessary personal
data.

Potential events: - `auth_started`, `auth_completed`, `auth_failed` -
`search_submitted`, `search_no_results` - `merchant_viewed`,
`product_viewed` - `item_added_to_cart`, `item_removed_from_cart` -
`checkout_started`, `checkout_validation_failed` -
`order_submit_started`, `order_submit_succeeded`,
`order_submit_failed` - `payment_started`, `payment_succeeded`,
`payment_failed` - `order_tracking_opened` - `permission_prompt_shown`,
`permission_result` - `screen_error_shown`, `offline_state_shown`

Rules: - Define event names and properties centrally. - Do not send full
addresses, phone numbers, passwords, tokens, payment details, or
sensitive pharmacy purchase details to analytics. - Keep analytics
failures from blocking user actions. - Use error monitoring for
diagnostics and product analytics for behavior; do not duplicate
sensitive payloads. - Add correlation/request IDs where available, but
do not expose internal diagnostics to the user unnecessarily.

------------------------------------------------------------------------

## 18. Testing and quality gates

Before marking a screen complete, verify:

### Visual

-   Correct tokens, typography, spacing, image ratios, and component
    variants.
-   No accidental overflow, clipping, or layout shifts.
-   No inconsistent icon styles, excessive shadows, or arbitrary colors.
-   Dark/light system behavior is intentional and documented.

### Functional

-   All primary and secondary actions work.
-   Loading, empty, error, offline, disabled, and success states are
    implemented.
-   Back navigation and state restoration work.
-   Double-taps do not create duplicate mutations.
-   Refreshing does not erase valid content on failure.

### Localization/accessibility

-   English LTR and Arabic RTL both work.
-   Long strings and large font settings do not break layouts.
-   Screen-reader labels and focus order are correct.
-   Touch targets and contrast are adequate.
-   Reduced-motion preferences are respected.

### Commerce correctness

-   Prices and totals are revalidated at checkout.
-   Discounts are server-confirmed.
-   Inventory/merchant availability changes are handled.
-   Unknown order/payment outcomes are resolved before retry.
-   Reorder validates current products and prices.

### Release

-   No secrets or debug content in the client.
-   No unhandled promise rejections or noisy production logs.
-   Crash/error monitoring is configured.
-   Test on slow network, offline, denied permissions, expired session,
    and server failure.
-   Verify app icon, splash, store screenshots, and branding assets at
    target sizes.

------------------------------------------------------------------------

## 19. Definition of done for every screen

A screen is not complete until all are true:

-   [ ] Its purpose and user flow are documented.
-   [ ] It uses approved tokens and shared components.
-   [ ] It follows the existing repository architecture.
-   [ ] It supports English and Arabic RTL.
-   [ ] It supports accessibility and scalable text.
-   [ ] It has loading, empty, error, offline, disabled, and success
    states where relevant.
-   [ ] It preserves user input after recoverable failures.
-   [ ] It prevents duplicate or unsafe mutations.
-   [ ] It handles permissions and navigation correctly.
-   [ ] It logs useful sanitized diagnostics without leaking sensitive
    data.
-   [ ] It has been tested on a small screen and a real or
    representative Android device.
-   [ ] No new folder, design token, component system, or dependency was
    introduced without checking existing project conventions.

------------------------------------------------------------------------

## 20. Guidance for AI coding agents

When working on Marketak UI:

1.  Read this `design.md` and the repository architecture/README before
    coding.
2.  Inspect existing components, tokens, routes, and data hooks before
    adding anything.
3.  State which existing files/components will be reused.
4.  Implement only the requested screen or scoped task; do not redesign
    unrelated screens.
5.  Do not create a new folder or parallel component library without
    explicit approval.
6.  Use design tokens and localized strings; do not hard-code visual
    values or user-facing text when a shared token/translation key
    belongs there.
7.  Implement every relevant UI state, not only the happy path.
8.  Use the real typed data layer; do not invent backend fields or fake
    production responses.
9.  Run available lint, typecheck, and tests; report failures honestly.
10. Summarize changed files, tested flows, known gaps, and any decisions
    that require product approval.

**Final principle:** Marketak should feel like one coherent, trusted
local marketplace. Consistency, clarity, and reliable recovery matter
more than decoration.
