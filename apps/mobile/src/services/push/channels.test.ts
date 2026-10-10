import { describe, expect, it } from "vitest";
import { DISPATCH_CHANNEL_ID, PUSH_CHANNELS, UPDATES_CHANNEL_ID } from "./channels";

describe("push channels", () => {
  it("declares exactly the dispatch + updates pair", () => {
    expect(PUSH_CHANNELS.map((channel) => channel.id).sort()).toEqual(
      [DISPATCH_CHANNEL_ID, UPDATES_CHANNEL_ID].sort(),
    );
  });

  it("interrupts for dispatch, informs for updates", () => {
    const dispatch = PUSH_CHANNELS.find((channel) => channel.id === DISPATCH_CHANNEL_ID);
    const updates = PUSH_CHANNELS.find((channel) => channel.id === UPDATES_CHANNEL_ID);
    expect(dispatch?.input.importance).toBe(7);
    expect(dispatch?.input.enableVibrate).toBe(true);
    expect(updates?.input.importance).toBe(5);
    expect(updates?.input.lockscreenVisibility).toBe(2);
  });
});
