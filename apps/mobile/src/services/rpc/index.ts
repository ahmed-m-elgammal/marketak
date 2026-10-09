/**
 * Typed database calls.
 *
 * A feature imports from here, never from `@/services/rpc/call`. `callRpc` is internal because
 * `dto.ts` is what makes a call safe: it ties a call site to the RPC signature it was written
 * against, so a server-side rename fails the build instead of returning null at runtime.
 */

export { callRpc, callRpcList } from "@/services/rpc/call";
export type { RpcParams } from "@/services/rpc/call";

export {
  completeProfile,
  fetchProfileStatus,
  placeOrder,
  quoteOrder,
  removeCartItem,
  upsertCartItem,
} from "@/services/rpc/api";

export type {
  DeliveryType,
  Grouping,
  Language,
  PaymentMethod,
  PlaceOrderResult,
  ProfileStatus,
  QuoteResult,
  QuoteTotals,
  RemoveCartItemResult,
  SelectedOption,
  UpsertCartItemResult,
  Uuid,
} from "@/services/rpc/dto";