/**
 * Query keys (mobile README §6).
 *
 * Every key carries its scope up front: `session` for the session,
 * `customer` / `rider` namespaces for role data, each with the user id —
 * a key without `userId` leaks the previous account's rows after a
 * sign-out and sign-in on the same device. A keyed cache is not a security
 * boundary; the `where` clauses in `reads.ts` are. Screens append params
 * after the user id; the namespace prefix is what role switches clear by.
 */
export function sessionKey(): readonly ["session"] {
  return ["session"];
}

export function riderProfileKey(userId: string): readonly ["rider", "profile", string] {
  return ["rider", "profile", userId];
}

export function customerOrdersKey(userId: string): readonly ["customer", "orders", string] {
  return ["customer", "orders", userId];
}

export function riderOffersKey(
  userId: string,
  latitude: number,
  longitude: number,
): readonly ["rider", "offers", string, { readonly latitude: number; readonly longitude: number }] {
  return ["rider", "offers", userId, { latitude, longitude }];
}

export function customerAddressesKey(userId: string): readonly ["customer", "addresses", string] {
  return ["customer", "addresses", userId];
}
