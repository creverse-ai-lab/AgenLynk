import assert from "node:assert/strict";
import test from "node:test";
import { createSocketSender } from "../src/socket-flow.js";

test("slow subscription is removed while the control connection remains usable", () => {
  const writes = [];
  const removed = [];
  const socket = {
    destroyed: false,
    writableLength: 101,
    write(value) { writes.push(JSON.parse(value)); },
    destroy() { this.destroyed = true; }
  };
  const sender = createSocketSender(socket, {
    unsubscribe: (id) => removed.push(`service:${id}`),
    removeSubscription: (id) => removed.push(`socket:${id}`),
    maxSubscriptionBytes: 100,
    maxConnectionBytes: 400
  });
  assert.equal(sender.sendEvent("sub-slow", { sequence: 1 }), false);
  assert.deepEqual(removed, ["service:sub-slow", "socket:sub-slow"]);
  assert.equal(socket.destroyed, false);
  assert.equal(writes[0].type, "subscription_error");
  sender.send({ id: "control", ok: true });
  assert.equal(writes[1].id, "control");
});

test("hard connection backpressure destroys the whole socket", () => {
  const socket = {
    destroyed: false,
    writableLength: 401,
    write() {},
    destroy() { this.destroyed = true; }
  };
  const sender = createSocketSender(socket, {
    unsubscribe() {},
    removeSubscription() {},
    maxSubscriptionBytes: 100,
    maxConnectionBytes: 400
  });
  assert.throws(() => sender.send({ id: "control" }), /connection buffer exceeded/);
  assert.equal(socket.destroyed, true);
});
