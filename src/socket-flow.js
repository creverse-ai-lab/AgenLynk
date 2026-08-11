// Sized for bursts, not steady state. A delegated worker streaming thinking
// output can emit thousands of chunk events inside one event-loop tick, and
// the daemon fans them out synchronously — writableLength spikes far past any
// "slow reader" level while the subscriber is perfectly healthy. At 1MB the
// monitor's subscription was being killed on every such burst, which the app
// showed as a red disconnect plus a "일부 이벤트를 불러오지 못했습니다" notice
// once the replay cursor had been pruned. These limits only need to catch a
// subscriber that has actually stopped reading; a desktop process that is
// 8MB behind and draining is not that.
export const MAX_SOCKET_BUFFER_BYTES = 8_000_000;
export const MAX_CONNECTION_BUFFER_BYTES = 16_000_000;

export function createSocketSender(socket, {
  unsubscribe,
  removeSubscription,
  maxSubscriptionBytes = MAX_SOCKET_BUFFER_BYTES,
  maxConnectionBytes = MAX_CONNECTION_BUFFER_BYTES
}) {
  const send = (message) => {
    if (socket.destroyed) throw new Error("Gateway socket closed");
    if (socket.writableLength > maxConnectionBytes) {
      socket.destroy(new Error("Gateway connection buffer exceeded"));
      throw new Error("Gateway connection buffer exceeded");
    }
    socket.write(`${JSON.stringify(message)}\n`);
  };

  return {
    send,
    sendEvent(subscriptionId, event) {
      if (socket.destroyed) throw new Error("Gateway socket closed");
      if (socket.writableLength > maxSubscriptionBytes) {
        unsubscribe(subscriptionId);
        removeSubscription(subscriptionId);
        if (socket.writableLength <= maxConnectionBytes) {
          send({ type: "subscription_error", subscriptionId, error: "Gateway subscriber is too slow" });
        }
        return false;
      }
      send({ type: "event", subscriptionId, event });
      return true;
    }
  };
}
