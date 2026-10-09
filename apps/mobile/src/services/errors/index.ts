/**
 * Failures a screen can present.
 *
 * `AppError` is the only error type that should reach a component. `parseServerError` is
 * exported so a feature that catches an error from somewhere other than `callRpc` — a storage
 * read, say — still converts it rather than leaking a raw exception into a component.
 */

export { AppError, isAppError, parseServerError } from "@/services/errors/app-error";
export type { AppErrorKind } from "@/services/errors/app-error";