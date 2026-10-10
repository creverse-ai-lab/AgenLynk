import assert from "node:assert/strict";
import { homedir } from "node:os";
import test from "node:test";
import {
  CHAT_POLL_MAX_WAIT_MS,
  chatOpenArgs,
  chatPermissionArgs,
  chatPollArgs,
  chatPromptArgs
} from "../src/app/notch-chat.js";

test("a chat opens an ask-policy session in the home folder unless told otherwise", () => {
  assert.deepEqual(chatOpenArgs({ provider: "grok" }), { provider: "grok", cwd: homedir(), permissionPolicy: "ask" });
  assert.deepEqual(
    chatOpenArgs({ provider: "codex", cwd: "/tmp", permissionPolicy: "read_only", model: "gpt-5" }),
    { provider: "codex", cwd: "/tmp", permissionPolicy: "read_only", model: "gpt-5" }
  );
});

test("a chat refuses an unknown provider or policy", () => {
  assert.throws(() => chatOpenArgs({ provider: "gemini" }), /provider must be one of/);
  assert.throws(() => chatOpenArgs({ provider: "claude", permissionPolicy: "yolo" }), /permissionPolicy/);
  assert.throws(() => chatOpenArgs({}), /provider is required/);
});

test("a prompt needs a session and some text", () => {
  assert.deepEqual(chatPromptArgs({ sessionId: "s1", text: "hi" }), { sessionId: "s1", prompt: "hi" });
  assert.throws(() => chatPromptArgs({ sessionId: "s1", text: "  " }), /text is required/);
  assert.throws(() => chatPromptArgs({ text: "hi" }), /sessionId is required/);
});

test("a poll always asks for the running text and caps its wait", () => {
  const args = chatPollArgs(new URLSearchParams({ sessionId: "s1", cursor: "7", waitMs: "999999" }));
  assert.deepEqual(args, {
    sessionId: "s1", cursor: 7, waitMs: CHAT_POLL_MAX_WAIT_MS, includeResult: true, includeToolEvents: true, responseProfile: "compact"
  });
  assert.equal(chatPollArgs(new URLSearchParams({ sessionId: "s1", cursor: "-3" })).cursor, 0);
});

test("a permission answer carries the request id as the Worker gave it", () => {
  assert.deepEqual(
    chatPermissionArgs({ sessionId: "s1", requestId: 4, optionId: "allow_once" }),
    { sessionId: "s1", requestId: 4, optionId: "allow_once" }
  );
  // Gateway 1.8 hands a Worker's string id back as a string, never coerced.
  assert.deepEqual(
    chatPermissionArgs({ sessionId: "s1", requestId: "req-7", optionId: "allow_once" }),
    { sessionId: "s1", requestId: "req-7", optionId: "allow_once" }
  );
  assert.throws(() => chatPermissionArgs({ sessionId: "s1" }), /requestId is required/);
  assert.throws(() => chatPermissionArgs({ sessionId: "s1", requestId: "" }), /requestId is required/);
  assert.throws(() => chatPermissionArgs({ sessionId: "s1", requestId: 1.5 }), /requestId is required/);
});
