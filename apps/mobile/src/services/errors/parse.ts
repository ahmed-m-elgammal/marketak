/**
 * The error import point for the services layer (mobile README §7, R4).
 *
 * Re-exports the shared parser. The behaviour layer extends it and never
 * reimplements it — a second parser is how the same failure is retried in
 * one flow and shown in another, and the depcruiser `no-second-error-parser`
 * rule fails one.
 */
import {
  AppError,
  isAppError,
  kindOfErrorCode,
  parseAppError,
  parseServerMessage,
} from "@marketak/shared";
import type { AppErrorKind, ParsedError } from "@marketak/shared";

export { AppError, isAppError, kindOfErrorCode, parseAppError, parseServerMessage };
export type { AppErrorKind, ParsedError };
