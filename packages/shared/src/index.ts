/**
 * `@marketak/shared` - the public surface.
 *
 * ## Import direction, one-way
 *
 * ```
 * adapters/      -> HTTP, PostgREST, anything outside the process
 * application/   -> use cases that coordinate the domain
 * domain/        -> facts about the business. No imports upward.
 * tests/         -> imports everything, asserts nothing is exported twice
 * ```
 *
 * Nothing in `domain/` may import from `application/` or `adapters/`. That is what keeps the money and
 * notification contracts reusable by the mobile app and the admin console, which will not want a
 * Cloudflare dependency.
 *
 * ## What lives where
 *
 * | Path | Holds |
 * |---|---|
 * | `domain/money/format-money.ts` | piastre formatting, currency validation |
 * | `domain/notifications/claim-contract.ts` | what `claim_events_v1` returns, and the Worker-owned strings |
 * | `application/render-notification.ts` | variables + template -> a sendable message |
 * | `adapters/` | reserved for future non-database I/O |
 * | `tests/` | **every test in this package, in one directory** |
 *
 * ## Tests are in `src/tests/`, not beside the source
 *
 * So that "where are the tests for the renderer" is answered by one path rather than a search. Filenames
 * match the module they cover: `tests/format-money.test.ts` covers `domain/money/format-money.ts`.
 */

export { formatCount, formatMoney, isCurrencyCode, PIASBRES } from "./domain/money/format-money.js";
export type { CurrencyCode, Piastres } from "./domain/money/format-money.js";

export {
  isSendable,
  placeholdersIn,
  renderTemplate,
} from "./application/render-notification.js";

export { WORKER_STATIC_VARIABLES } from "./domain/notifications/claim-contract.js";
export type {
  ClaimedNotification,
  DeviceTokenRow,
  Language,
  MarkResult,
  NotificationVariables,
  Recipient,
  RenderedNotification,
  SendOutcome,
  TemplateRow,
} from "./domain/notifications/claim-contract.js";