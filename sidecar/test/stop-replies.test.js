import assert from "node:assert/strict";
import test from "node:test";
import { StopReplies, isFrontdoorStop, isStopPayload, stopReplyDecision } from "../src/hooks/stop-replies.js";

test("only a Stop is held, in both payload spellings", () => {
  assert.equal(isStopPayload({ hook_event_name: "Stop" }), true);
  assert.equal(isStopPayload({ hookEventName: "stop" }), true);
  assert.equal(isStopPayload({ hook_event_name: "SubagentStop" }), false);
  assert.equal(isStopPayload({ hook_event_name: "StopFailure" }), false);
});

// Regression: a Claude sub-agent's Stop (it carries agent_id) was held like
// the Frontdoor's own, freezing the turn that was still running for up to
// 140 s and sending a reply to the sub-agent.
test("a sub-agent's Stop is not the Frontdoor's", () => {
  assert.equal(isFrontdoorStop("claude", { hook_event_name: "Stop", session_id: "c1" }), true);
  assert.equal(isFrontdoorStop("claude", { hook_event_name: "Stop", session_id: "c1", agent_id: "a1" }), false);
  assert.equal(isFrontdoorStop("codex", { hookEventName: "stop", agentId: "a1" }), false);
  assert.equal(isFrontdoorStop("grok", { hook_event_name: "Stop", agentId: "g1" }), true, "Grok's agentId is its session's own");
});

test("an answer resolves the slot with the reply the agent continues with", async () => {
  const replies = new StopReplies({ windowMs: 1_000 });
  const { slot, reply } = replies.open({ provider: "claude", sessionId: "local:claude:a", payload: { last_assistant_message: " done " } });
  assert.equal(slot.lastMessage, "done");
  assert.equal(replies.answer(slot.id, "  이어서 테스트도 돌려줘 "), true);
  assert.equal(await reply, "이어서 테스트도 돌려줘");
  assert.deepEqual(replies.list(), []);
  assert.deepEqual(JSON.parse(stopReplyDecision("go")), { decision: "block", reason: "사용자가 AgenLynk 노치에서 답장했습니다:\ngo" });
});

test("a dismissal, a timeout or a newer Stop lets the agent stop", async () => {
  // The window timer is unref'd (in the sidecar its HTTP server keeps the
  // process up); here something must, or Node 22 ends the test while the
  // timeout is still pending.
  const keepAlive = setInterval(() => {}, 1_000);
  try {
    const replies = new StopReplies({ windowMs: 20 });
    const dismissed = replies.open({ provider: "codex", sessionId: "s1" });
    replies.dismiss(dismissed.slot.id);
    assert.equal(await dismissed.reply, null);
    const timedOut = replies.open({ provider: "codex", sessionId: "s2" });
    assert.equal(await timedOut.reply, null);
    const first = replies.open({ provider: "grok", sessionId: "s3" });
    const second = replies.open({ provider: "grok", sessionId: "s3" });
    assert.equal(await first.reply, null);
    assert.deepEqual(replies.list().map((slot) => slot.id), [second.slot.id]);
    replies.closeAll();
    assert.equal(await second.reply, null);
  } finally {
    clearInterval(keepAlive);
  }
});

test("typing extends the window but never past the cap", () => {
  let now = 0;
  const replies = new StopReplies({ windowMs: 10_000, maxWindowMs: 25_000, now: () => now });
  const { slot } = replies.open({ provider: "claude", sessionId: "s" });
  now = 5_000;
  assert.equal(replies.extend(slot.id).expiresAt, 15_000);
  now = 20_000;
  assert.equal(replies.extend(slot.id).expiresAt, 25_000, "never past the cap");
  assert.equal(replies.answer(slot.id, "ok"), true);
  assert.throws(() => replies.answer("missing", "  "), /text is required/);
});
