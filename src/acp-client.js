import { spawn } from "node:child_process";
import { readFile, realpath, writeFile } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { StringDecoder } from "node:string_decoder";
import { BoundedUtf8Text } from "./bounded-utf8.js";
import { readNdjson } from "./ndjson.js";
import { GATEWAY_VERSION } from "./version.js";
import { ACP_PROTOCOL_VERSION } from "./acp-version.js";
import { delegatedWorkerEnvironment } from "./process-environment.js";

export const PERMISSION_POLICIES = ["ask", "read_only", "auto_approve"];
const READ_ONLY_TOOL_KINDS = new Set(["read", "search", "think", "fetch"]);
// Only the Claude adapter understands the `claudeCode` session meta namespace;
// every other provider would have to guess at options it never declared.
const THOUGHT_STREAM_PROVIDERS = new Set(["claude"]);

// Recent Claude models leave `thinking.display` at the API default "omitted",
// which streams signature-only thinking blocks whose text is empty — and the
// adapter drops those instead of emitting `agent_thought_chunk`. The adapter
// forwards `_meta.claudeCode.options` straight into the Agent SDK query, where
// this becomes `--thinking adaptive --thinking-display summarized`, so it is
// the only place a Worker's reasoning can be turned back on for the Gateway.
function thoughtStreamMeta() {
  return { claudeCode: { options: { thinking: { type: "adaptive", display: "summarized" } } } };
}

export class AcpClient {
  constructor(config, options = {}) {
    this.config = config;
    this.permissionPolicy = options.permissionPolicy ?? config.permissionPolicy;
    this.onExit = options.onExit;
    this.artifactStore = options.artifactStore ?? null;
    this.maxTerminalsPerSession = options.maxTerminalsPerSession ?? 16;
    this.maxPendingRequestsPerSession = options.maxPendingRequestsPerSession ?? 64;
    this.maxFrameBytes = options.maxFrameBytes ?? 32 * 1024 * 1024;
    this.thoughtStream = options.thoughtStream ?? true;
    this.proc = null;
    this.rl = null;
    this.nextId = 1;
    this.pending = new Map();
    this.pendingPermissions = new Map();
    this.pendingElicitations = new Map();
    this.pendingOperations = new Map();
    this.sessionOperationGrants = new Map();
    this.sessionHandlers = new Map();
    this.sessionRoots = new Map();
    this.sessionPolicies = new Map();
    this.terminals = new Map();
    this.initResult = null;
    this.startPromise = null;
    this.stderrListener = null;
    this.stderr = "";
    this.alive = false;
  }

  async start() {
    if (this.initResult) return this.initResult;
    if (this.startPromise) return this.startPromise;

    const attempt = this.#startProcess();
    this.startPromise = attempt;
    try {
      return await attempt;
    } finally {
      if (this.startPromise === attempt) this.startPromise = null;
    }
  }

  async #startProcess() {
    if (this.alive) throw new Error(`${this.config.provider} ACP is already starting`);

    const childEnv = delegatedWorkerEnvironment(process.env, { ...this.config.env, NO_COLOR: "1" });
    this.proc = spawn(this.config.command, this.config.args, {
      stdio: ["pipe", "pipe", "pipe"],
      env: childEnv
    });
    this.alive = true;
    this.stderr = "";
    this.proc.once("error", (error) => this.#fail(error));
    this.proc.once("close", (code, signal) => {
      this.#fail(new Error(`${this.config.provider} ACP exited code=${code} signal=${signal}`));
    });
    this.proc.stderr.setEncoding("utf8");
    this.stderrListener = (chunk) => {
      this.stderr = (this.stderr + chunk).slice(-100_000);
    };
    this.proc.stderr.on("data", this.stderrListener);
    this.rl = readNdjson(this.proc.stdout, {
      maxLineBytes: this.maxFrameBytes,
      onLine: (line) => this.#onLine(line),
      onOverflow: (error) => {
        this.proc?.kill("SIGTERM");
        this.#fail(error);
      }
    });

    try {
      this.initResult = await this.request(
        "initialize",
        {
          protocolVersion: ACP_PROTOCOL_VERSION,
          clientInfo: { name: "acp-gateway", version: GATEWAY_VERSION },
          clientCapabilities: {
            fs: { readTextFile: true, writeTextFile: true },
            terminal: true,
            elicitation: { form: {} },
            session: { configOptions: { boolean: {} } }
          }
        },
        30_000
      );
      return this.initResult;
    } catch (error) {
      this.#fail(error);
      throw error;
    }
  }

  async stop() {
    for (const rpcId of this.pendingPermissions.keys()) {
      this.respondPermission(rpcId, null);
    }
    for (const rpcId of this.pendingElicitations.keys()) {
      this.respondElicitation(rpcId, { action: "cancel" });
    }
    for (const terminal of this.terminals.values()) terminal.child.kill("SIGTERM");
    this.terminals.clear();
    const error = new Error("ACP client stopped");
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
    for (const operation of this.pendingOperations.values()) operation.reject(error);
    this.pendingOperations.clear();
    this.sessionOperationGrants.clear();
    this.#disposeProcess();
  }

  request(method, params = {}, timeoutMs = null) {
    if (!this.proc?.stdin) throw new Error("ACP process is not running");
    const id = this.nextId++;
    const payload = { jsonrpc: "2.0", id, method, params };

    return new Promise((resolvePromise, reject) => {
      const timer = timeoutMs
        ? setTimeout(() => {
            this.pending.delete(id);
            reject(new Error(`ACP request timeout after ${timeoutMs}ms: ${method}`));
          }, timeoutMs)
        : null;
      this.pending.set(id, {
        method,
        resolve: (value) => {
          if (timer) clearTimeout(timer);
          resolvePromise(value);
        },
        reject: (error) => {
          if (timer) clearTimeout(timer);
          reject(error);
        }
      });
      this.proc.stdin.write(`${JSON.stringify(payload)}\n`);
    });
  }

  notify(method, params = {}) {
    this.proc?.stdin?.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
  }

  // Provider-specific session options the Gateway asks every Worker session for,
  // or null when this provider has no such knob and the params stay untouched.
  sessionMeta() {
    if (!this.thoughtStream) return null;
    if (!THOUGHT_STREAM_PROVIDERS.has(this.config.provider)) return null;
    return thoughtStreamMeta();
  }

  async sessionNew({
    cwd,
    mcpServers = [],
    additionalDirectories = [],
    permissionPolicy = this.permissionPolicy
  }) {
    const roots = await canonicalRoots(cwd, additionalDirectories);
    const params = { cwd: roots[0], mcpServers };
    if (additionalDirectories.length) params.additionalDirectories = roots.slice(1);
    const meta = this.sessionMeta();
    if (meta) params._meta = meta;
    const result = await this.request("session/new", params, 30_000);
    this.sessionRoots.set(result.sessionId, roots);
    this.sessionPolicies.set(result.sessionId, requirePermissionPolicy(permissionPolicy));
    return result;
  }

  async sessionRestore({
    method,
    sessionId,
    cwd,
    mcpServers = [],
    additionalDirectories = [],
    permissionPolicy = this.permissionPolicy
  }) {
    const roots = await canonicalRoots(cwd, additionalDirectories);
    const params = { sessionId, cwd: roots[0], mcpServers };
    if (additionalDirectories.length) params.additionalDirectories = roots.slice(1);
    // Restores rebuild the underlying query, so they need the same meta as
    // session/new — otherwise an idle-unloaded Worker comes back thought-blind.
    const meta = this.sessionMeta();
    if (meta) params._meta = meta;
    const result = await this.request(method, params, 30_000);
    this.sessionRoots.set(sessionId, roots);
    this.sessionPolicies.set(sessionId, requirePermissionPolicy(permissionPolicy));
    return result;
  }

  sessionPrompt({ sessionId, prompt }) {
    const content = Array.isArray(prompt) ? prompt : [{ type: "text", text: String(prompt) }];
    return this.request("session/prompt", { sessionId, prompt: content })
      .finally(() => this.sessionOperationGrants.delete(sessionId));
  }

  setSessionConfigOption({ sessionId, configId, value, type = null }) {
    const params = { sessionId, configId, value };
    if (type != null) params.type = type;
    return this.request("session/set_config_option", params, 30_000);
  }

  pendingSessionInput(sessionId) {
    let permissions = 0;
    let elicitations = 0;
    for (const pending of this.pendingPermissions.values()) {
      if (pending.params.sessionId === sessionId) permissions += 1;
    }
    for (const pending of this.pendingOperations.values()) {
      if (pending.sessionId === sessionId) permissions += 1;
    }
    for (const pending of this.pendingElicitations.values()) {
      if (pending.params.sessionId === sessionId) elicitations += 1;
    }
    return { permissions, elicitations };
  }

  cancelSession(sessionId) {
    for (const [rpcId, pending] of this.pendingPermissions) {
      if (pending.params.sessionId === sessionId) this.respondPermission(rpcId, null);
    }
    for (const [rpcId, pending] of this.pendingElicitations) {
      if (pending.params.sessionId === sessionId) {
        this.respondElicitation(rpcId, { action: "cancel" }, sessionId);
      }
    }
    this.#rejectSessionOperations(sessionId, new Error("ACP session cancelled"));
    this.#closeSessionTerminals(sessionId);
    this.notify("session/cancel", { sessionId });
  }

  onSessionUpdate(sessionId, handler) {
    this.sessionHandlers.set(sessionId, handler);
  }

  clearSession(sessionId) {
    for (const [rpcId, pending] of this.pendingElicitations) {
      if (pending.params.sessionId === sessionId) {
        this.respondElicitation(rpcId, { action: "cancel" }, sessionId);
      }
    }
    this.#closeSessionTerminals(sessionId);
    this.sessionHandlers.delete(sessionId);
    this.sessionRoots.delete(sessionId);
    this.sessionPolicies.delete(sessionId);
    this.#rejectSessionOperations(sessionId, new Error("ACP session cleared"));
    this.sessionOperationGrants.delete(sessionId);
  }

  respondPermission(rpcId, optionId, expectedSessionId) {
    const operation = this.pendingOperations.get(rpcId);
    if (operation) {
      if (expectedSessionId && operation.sessionId !== expectedSessionId) {
        throw new Error(`Permission request ${rpcId} belongs to another session`);
      }
      this.pendingOperations.delete(rpcId);
      const allowed = operation.options.some(
        (option) => option.optionId === optionId && /^allow_/.test(option.kind)
      );
      if (!allowed) {
        operation.reject(new Error("Main rejected ACP operation"));
        return;
      }
      return Promise.resolve()
        .then(() => operation.run())
        .then(operation.resolve, operation.reject);
    }
    const pending = this.pendingPermissions.get(rpcId);
    if (!pending) throw new Error(`Unknown permission request: ${rpcId}`);
    if (expectedSessionId && pending.params.sessionId !== expectedSessionId) {
      throw new Error(`Permission request ${rpcId} belongs to another session`);
    }
    if (optionId && !(pending.params.options ?? []).some((option) => option.optionId === optionId)) {
      throw new Error(`Invalid permission option: ${optionId}`);
    }
    this.pendingPermissions.delete(rpcId);
    if (!READ_ONLY_TOOL_KINDS.has(pending.params.toolCall?.kind) && optionId && (pending.params.options ?? []).some(
      (option) => option.optionId === optionId && /^allow_/.test(option.kind ?? "")
    )) {
      this.#addOperationGrant(pending.params.sessionId, grantKindForTool(pending.params.toolCall?.kind));
    }
    const outcome = optionId
      ? { outcome: "selected", optionId }
      : { outcome: "cancelled" };
    this.#respond(rpcId, { outcome });
  }

  respondElicitation(rpcId, response, expectedSessionId) {
    const pending = this.pendingElicitations.get(rpcId);
    if (!pending) throw new Error(`Unknown elicitation request: ${rpcId}`);
    if (expectedSessionId && pending.params.sessionId !== expectedSessionId) {
      throw new Error(`Elicitation request ${rpcId} belongs to another session`);
    }
    if (!response || !["accept", "decline", "cancel"].includes(response.action)) {
      throw new Error("Elicitation action must be accept, decline, or cancel");
    }
    if (response.action === "accept" && response.content != null && (
      typeof response.content !== "object" || Array.isArray(response.content)
    )) {
      throw new Error("Accepted elicitation content must be an object");
    }
    this.pendingElicitations.delete(rpcId);
    this.#respond(rpcId, response);
  }

  #onLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }

    if (Object.hasOwn(message, "id") && (Object.hasOwn(message, "result") || message.error)) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(new Error(`ACP error ${message.error.code ?? ""}: ${message.error.message}`));
      } else {
        pending.resolve(message.result);
      }
      return;
    }

    if (message.method === "session/update") {
      const params = message.params ?? {};
      this.sessionHandlers.get(params.sessionId)?.(params.update ?? params);
      return;
    }

    if (message.method && Object.hasOwn(message, "id")) {
      void this.#handleAgentRequest(message);
    }
  }

  async #handleAgentRequest({ id, method, params = {} }) {
    try {
      if (method === "session/request_permission") {
        const decision = this.#automaticPermission(params);
        if (decision) this.#respond(id, decision);
        else {
          this.#requirePendingInputCapacity(params.sessionId);
          this.pendingPermissions.set(id, { rpcId: id, params });
          this.sessionHandlers.get(params.sessionId)?.({
            sessionUpdate: "permission_request",
            requestId: id,
            toolCall: params.toolCall,
            options: params.options
          });
        }
        return;
      }
      if (method === "elicitation/create") {
        if (!params.sessionId) throw new Error("Only session-scoped elicitation is supported");
        if (params.mode !== "form") throw new Error(`Unsupported elicitation mode: ${params.mode}`);
        this.#requirePendingInputCapacity(params.sessionId);
        this.pendingElicitations.set(id, { rpcId: id, params });
        this.sessionHandlers.get(params.sessionId)?.({
          sessionUpdate: "elicitation_request",
          requestId: id,
          mode: params.mode,
          message: params.message,
          requestedSchema: params.requestedSchema,
          toolCallId: params.toolCallId ?? null
        });
        return;
      }
      if (method === "fs/read_text_file") {
        this.#respond(id, await this.#readTextFile(params));
        return;
      }
      if (method === "fs/write_text_file") {
        await this.#runProtectedOperation(id, method, params, () => this.#writeTextFile(params));
        return;
      }
      if (method === "terminal/create") {
        await this.#runProtectedOperation(id, method, params, () => this.#createTerminal(params));
        return;
      }
      if (method === "terminal/output") {
        this.#respond(id, this.#terminalOutput(params));
        return;
      }
      if (method === "terminal/release") {
        this.#respond(id, this.#releaseTerminal(params));
        return;
      }
      if (method === "terminal/wait_for_exit") {
        this.#respond(id, await this.#waitForTerminalExit(params));
        return;
      }
      if (method === "terminal/kill") {
        this.#respond(id, this.#killTerminal(params));
        return;
      }
      this.#respondError(id, -32601, `Unsupported ACP client method: ${method}`);
    } catch (error) {
      this.#respondError(id, -32000, error?.message ?? String(error));
    }
  }

  #automaticPermission(params) {
    const policy = this.sessionPolicies.get(params.sessionId) ?? this.permissionPolicy;
    if (policy === "ask") return null;
    const options = params.options ?? [];
    const readLike = READ_ONLY_TOOL_KINDS.has(params.toolCall?.kind);
    const wantedKinds = policy === "auto_approve" || readLike
      ? ["allow_once", "allow_always"]
      : ["reject_once", "reject_always"];
    const option = wantedKinds.map((kind) => options.find((item) => item.kind === kind)).find(Boolean);
    return { outcome: option ? { outcome: "selected", optionId: option.optionId } : { outcome: "cancelled" } };
  }

  async #readTextFile(params) {
    const path = await this.#sessionPath(params.sessionId, params.path);
    const content = await readFile(path, "utf8");
    if (params.line == null && params.limit == null) {
      return { content: content.slice(0, 500_000) };
    }
    const lines = content.split("\n");
    const start = Math.max(0, Number(params.line ?? 1) - 1);
    const limit = params.limit == null ? lines.length : Math.max(0, Number(params.limit));
    return { content: lines.slice(start, start + limit).join("\n").slice(0, 500_000) };
  }

  async #writeTextFile(params) {
    const path = await this.#sessionPath(params.sessionId, params.path, true);
    await writeFile(path, String(params.content ?? ""), "utf8");
  }

  async #createTerminal(params) {
    const roots = this.sessionRoots.get(params.sessionId) ?? [];
    const cwd = await realpath(resolve(params.cwd ?? roots[0] ?? process.cwd()));
    if (!roots.some((root) => isWithin(root, cwd))) throw new Error(`Terminal cwd is outside ACP session roots: ${cwd}`);
    if (typeof params.command !== "string" || !params.command) throw new Error("Terminal command is required");
    const activeForSession = [...this.terminals.values()].filter((item) => item.sessionId === params.sessionId).length;
    if (activeForSession >= this.maxTerminalsPerSession) {
      throw new Error(`ACP session terminal limit exceeded: ${this.maxTerminalsPerSession}`);
    }
    const terminalId = `terminal-${this.nextId++}`;
    const limit = Math.min(Math.max(Number(params.outputByteLimit ?? 1_000_000), 1), 10_000_000);
    const env = delegatedWorkerEnvironment(
      process.env,
      Object.fromEntries((params.env ?? []).map(({ name, value }) => [name, value]))
    );
    const child = spawn(params.command, params.args ?? [], {
      cwd,
      env,
      stdio: ["ignore", "pipe", "pipe"],
      detached: process.platform !== "win32"
    });
    const artifactWriter = this.artifactStore?.create(params.sessionId, "terminal") ?? null;
    const outputBuffer = new BoundedUtf8Text(limit, { onTrim: (buffer) => artifactWriter?.append(buffer) });
    const terminal = {
      child,
      sessionId: params.sessionId,
      outputBuffer,
      artifactWriter,
      artifact: null,
      limit,
      truncated: false,
      exitStatus: null,
      exited: null
    };
    const stdoutDecoder = new StringDecoder("utf8");
    const stderrDecoder = new StringDecoder("utf8");
    terminal.exited = new Promise((done) => {
      let finished = false;
      const finish = (exitCode, signal) => {
        if (finished) return;
        finished = true;
        terminal.exitStatus = { exitCode, signal };
        done(terminal.exitStatus);
      };
      child.once("close", (exitCode, signal) => {
        append(stdoutDecoder.end());
        append(stderrDecoder.end());
        if (artifactWriter?.active) {
          artifactWriter.finalize(outputBuffer.toString());
          terminal.artifact = artifactWriter.metadata();
        }
        finish(exitCode, signal);
      });
      child.once("error", (error) => {
        append(`\n${error.message}\n`);
        if (artifactWriter?.active) {
          artifactWriter.finalize(outputBuffer.toString());
          terminal.artifact = artifactWriter.metadata();
        }
        finish(null, null);
      });
    });
    const append = (chunk) => {
      outputBuffer.append(chunk);
      if (outputBuffer.trimmedBytes > 0) terminal.truncated = true;
    };
    child.stdout.on("data", (chunk) => append(stdoutDecoder.write(chunk)));
    child.stderr.on("data", (chunk) => append(stderrDecoder.write(chunk)));
    this.terminals.set(terminalId, terminal);
    return { terminalId };
  }

  #terminalOutput(params) {
    const terminal = this.#terminal(params.sessionId, params.terminalId);
    return {
      output: terminal.outputBuffer.toString(),
      artifact: terminal.artifact ?? terminal.artifactWriter?.metadata() ?? null,
      truncated: terminal.truncated,
      exitStatus: terminal.exitStatus
    };
  }

  #releaseTerminal(params) {
    const terminal = this.#terminal(params.sessionId, params.terminalId);
    if (!terminal.exitStatus) terminateChild(terminal);
    this.terminals.delete(params.terminalId);
    return {};
  }

  async #waitForTerminalExit(params) {
    const terminal = this.#terminal(params.sessionId, params.terminalId);
    return await terminal.exited;
  }

  #killTerminal(params) {
    const terminal = this.#terminal(params.sessionId, params.terminalId);
    if (!terminal.exitStatus) killChild(terminal.child, params.signal ?? "SIGTERM");
    return {};
  }

  #terminal(sessionId, terminalId) {
    const terminal = this.terminals.get(terminalId);
    if (!terminal) throw new Error(`Unknown terminalId: ${terminalId}`);
    if (terminal.sessionId !== sessionId) throw new Error(`Terminal ${terminalId} belongs to another session`);
    return terminal;
  }

  async #sessionPath(sessionId, requestedPath, allowMissing = false) {
    const roots = this.sessionRoots.get(sessionId) ?? [];
    const requested = resolve(requestedPath);
    let path;
    try {
      path = await realpath(requested);
    } catch (error) {
      if (!allowMissing || error?.code !== "ENOENT") throw error;
      path = join(await realpath(dirname(requested)), basename(requested));
    }
    if (!roots.some((root) => isWithin(root, path))) throw new Error(`Path is outside ACP session roots: ${path}`);
    return path;
  }

  async #runProtectedOperation(id, method, params, run) {
    const policy = this.sessionPolicies.get(params.sessionId) ?? this.permissionPolicy;
    if (policy === "read_only") throw new Error("Session permission policy is read_only");
    if (policy === "auto_approve") {
      this.#respond(id, await run() ?? {});
      return;
    }
    const operationKind = method === "fs/write_text_file" ? "write" : "terminal";
    const sessionGrants = this.sessionOperationGrants.get(params.sessionId);
    const grants = sessionGrants?.get(operationKind) ?? 0;
    if (grants > 0) {
      sessionGrants.set(operationKind, grants - 1);
      this.#respond(id, await run() ?? {});
      return;
    }
    const options = [
      { optionId: "allow-once", name: "Allow once", kind: "allow_once" },
      { optionId: "reject-once", name: "Reject", kind: "reject_once" }
    ];
    this.#requirePendingInputCapacity(params.sessionId);
    await new Promise((done) => {
      this.pendingOperations.set(id, {
        sessionId: params.sessionId,
        operationKind,
        options,
        run,
        resolve: (result) => { this.#respond(id, result ?? {}); done(); },
        reject: (error) => { this.#respondError(id, -32001, error.message); done(); }
      });
      this.sessionHandlers.get(params.sessionId)?.({
        sessionUpdate: "permission_request",
        requestId: id,
        toolCall: { toolCallId: `client-${id}`, title: method, kind: method === "fs/write_text_file" ? "edit" : "execute" },
        options
      });
    });
  }

  #closeSessionTerminals(sessionId) {
    for (const [terminalId, terminal] of this.terminals) {
      if (terminal.sessionId !== sessionId) continue;
      if (!terminal.exitStatus) terminateChild(terminal);
      this.terminals.delete(terminalId);
    }
  }

  #addOperationGrant(sessionId, operationKind) {
    if (!operationKind) return;
    let grants = this.sessionOperationGrants.get(sessionId);
    if (!grants) {
      grants = new Map();
      this.sessionOperationGrants.set(sessionId, grants);
    }
    grants.set(operationKind, (grants.get(operationKind) ?? 0) + 1);
  }

  #requirePendingInputCapacity(sessionId) {
    const pending = this.pendingSessionInput(sessionId);
    if (pending.permissions + pending.elicitations >= this.maxPendingRequestsPerSession) {
      throw new Error(`ACP session pending request limit exceeded: ${this.maxPendingRequestsPerSession}`);
    }
  }

  #rejectSessionOperations(sessionId, error) {
    for (const [rpcId, operation] of this.pendingOperations) {
      if (operation.sessionId !== sessionId) continue;
      this.pendingOperations.delete(rpcId);
      operation.reject(error);
    }
  }

  #respond(id, result) {
    this.proc?.stdin?.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
  }

  #respondError(id, code, message) {
    this.proc?.stdin?.write(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } })}\n`);
  }

  #fail(error) {
    const wasAlive = this.alive;
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
    this.pendingPermissions.clear();
    this.pendingElicitations.clear();
    for (const operation of this.pendingOperations.values()) operation.reject(error);
    this.pendingOperations.clear();
    this.sessionOperationGrants.clear();
    for (const terminal of this.terminals.values()) {
      if (!terminal.exitStatus) terminateChild(terminal);
    }
    this.terminals.clear();
    this.#disposeProcess();
    if (wasAlive) this.onExit?.(error);
  }

  #disposeProcess() {
    const proc = this.proc;
    const reader = this.rl;
    const stderrListener = this.stderrListener;
    this.alive = false;
    this.proc = null;
    this.rl = null;
    this.stderrListener = null;
    this.initResult = null;
    reader?.close();
    if (stderrListener) proc?.stderr?.off("data", stderrListener);
    proc?.stdin?.end();
    if (proc && proc.exitCode == null && proc.signalCode == null) proc.kill("SIGTERM");
  }
}

function grantKindForTool(toolKind) {
  if (toolKind === "edit" || toolKind === "delete" || toolKind === "move") return "write";
  if (toolKind === "execute") return "terminal";
  return null;
}

function killChild(child, signal) {
  try {
    if (process.platform !== "win32" && child.pid) process.kill(-child.pid, signal);
    else child.kill(signal);
  } catch (error) {
    if (error?.code !== "ESRCH") throw error;
  }
}

function terminateChild(terminal) {
  killChild(terminal.child, "SIGTERM");
  const timer = setTimeout(() => {
    if (!terminal.exitStatus) killChild(terminal.child, "SIGKILL");
  }, 2_000);
  timer.unref();
}

function isWithin(root, path) {
  const rel = relative(root, path);
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

async function canonicalRoots(cwd, additionalDirectories) {
  return await Promise.all([cwd, ...additionalDirectories].map((path) => realpath(resolve(path))));
}

export function requirePermissionPolicy(policy) {
  if (!PERMISSION_POLICIES.includes(policy)) {
    throw new Error(`permissionPolicy must be one of: ${PERMISSION_POLICIES.join(", ")}`);
  }
  return policy;
}
