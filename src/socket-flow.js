export const MAX_SOCKET_BUFFER_BYTES = 1_000_000;
export const MAX_CONNECTION_BUFFER_BYTES = 4_000_000;

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
