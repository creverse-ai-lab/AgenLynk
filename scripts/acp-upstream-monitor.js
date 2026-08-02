#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ACP_REGISTRY_URL, validateRegistry } from "../src/acp-registry.js";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const defaults = {
  configPath: resolve(root, "config/acp-monitor.json"),
  snapshotPath: resolve(root, "config/acp-upstream.snapshot.json"),
  reportPath: null,
  update: false,
  validate: false
};

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    const config = JSON.parse(await readFile(options.configPath, "utf8"));
    validateMonitorConfig(config);
    const previous = JSON.parse(await readFile(options.snapshotPath, "utf8"));
    validateSnapshot(previous, config);

    if (options.validate) {
      process.stdout.write("ACP upstream snapshot is valid\n");
    } else {
      const current = await collectUpstream(config);
      const changes = compareSnapshots(previous, current, config);
      const report = renderReport(changes, current, config);
      if (options.reportPath) await writeFile(options.reportPath, report, "utf8");
      if (options.update && changes.length) {
        await writeFile(options.snapshotPath, `${JSON.stringify(current, null, 2)}\n`, "utf8");
      }
      process.stdout.write(report);
      if (!options.update && changes.length) process.exitCode = 2;
    }
  } catch (error) {
    process.stderr.write(`acp-upstream-monitor: ${error?.message ?? String(error)}\n`);
    process.exitCode = 1;
  }
}

export async function collectUpstream(config, { fetchImpl = globalThis.fetch } = {}) {
  const headers = {
    accept: "application/vnd.github+json",
    "user-agent": "acp-gateway-upstream-monitor",
    ...(process.env.GITHUB_TOKEN ? { authorization: `Bearer ${process.env.GITHUB_TOKEN}` } : {})
  };
  const repository = config.protocolRepository;
  const [registry, release, schemaEntries] = await Promise.all([
    fetchJson(ACP_REGISTRY_URL, { fetchImpl, maxBytes: 5 * 1024 * 1024 }),
    fetchJson(`https://api.github.com/repos/${repository}/releases/latest`, { fetchImpl, headers }),
    fetchJson(`https://api.github.com/repos/${repository}/contents/schema`, { fetchImpl, headers })
  ]);
  validateRegistry(registry);
  if (!release?.tag_name || !release?.html_url || !release?.published_at) {
    throw new Error("ACP protocol latest release response is incomplete");
  }
  if (!Array.isArray(schemaEntries)) throw new Error("ACP protocol schema listing is invalid");

  const schemaDirectories = schemaEntries
    .filter((entry) => entry?.type === "dir" && /^v\d+$/.test(entry.name))
    .map((entry) => entry.name)
    .sort((left, right) => Number(left.slice(1)) - Number(right.slice(1)));
  const metas = await Promise.all(schemaDirectories.map((directory) => fetchJson(
    `https://raw.githubusercontent.com/${repository}/main/schema/${directory}/meta.json`,
    { fetchImpl, maxBytes: 1024 * 1024 }
  )));
  const availableWireVersions = [...new Set(metas.map((meta) => Number(meta?.version)))]
    .filter((version) => Number.isInteger(version) && version > 0)
    .sort((left, right) => left - right);
  if (!availableWireVersions.length) throw new Error("ACP protocol exposes no valid wire versions");

  const agentIds = config.watchAllRegistryAgents
    ? registry.agents.map((agent) => agent.id).sort()
    : [...config.watchedAgents].sort();
  const agents = {};
  for (const id of agentIds) {
    const agent = registry.agents.find((item) => item.id === id);
    if (!agent) throw new Error(`Watched ACP registry agent is missing: ${id}`);
    agents[id] = { version: agent.version, distribution: sortObject(agent.distribution) };
  }

  return {
    schemaVersion: 1,
    protocol: {
      latestRelease: {
        tag: release.tag_name,
        publishedAt: release.published_at,
        url: release.html_url
      },
      availableWireVersions
    },
    registry: {
      documentVersion: registry.version,
      agents
    }
  };
}

export function compareSnapshots(previous, current, config) {
  const changes = [];
  addChange(changes, "protocol.release", previous.protocol.latestRelease.tag, current.protocol.latestRelease.tag);
  addChange(
    changes,
    "protocol.wireVersions",
    previous.protocol.availableWireVersions.join(","),
    current.protocol.availableWireVersions.join(",")
  );
  addChange(changes, "registry.document", previous.registry.documentVersion, current.registry.documentVersion);
  const agentIds = config.watchAllRegistryAgents
    ? [...new Set([
        ...Object.keys(previous.registry.agents),
        ...Object.keys(current.registry.agents)
      ])].sort()
    : config.watchedAgents;
  for (const id of agentIds) {
    addChange(changes, `registry.${id}`, previous.registry.agents[id]?.version, current.registry.agents[id]?.version);
    const before = stableJson(previous.registry.agents[id]?.distribution ?? null);
    const after = stableJson(current.registry.agents[id]?.distribution ?? null);
    if (before !== after && previous.registry.agents[id]?.version === current.registry.agents[id]?.version) {
      changes.push({ component: `registry.${id}.distribution`, before, after });
    }
  }
  return changes;
}

export function renderReport(changes, current, config) {
  const unsupported = current.protocol.availableWireVersions.filter(
    (version) => !config.supportedWireVersions.includes(version)
  );
  const lines = ["# ACP Upstream Monitor", ""];
  if (!changes.length) lines.push("No upstream version changes detected.", "");
  else {
    lines.push("Upstream changes were detected. This PR updates the monitored snapshot and managed adapter pins; merge after compatibility review.", "");
    lines.push("| Component | Before | After |", "|---|---:|---:|");
    for (const change of changes) {
      lines.push(`| ${escapeCell(change.component)} | ${escapeCell(change.before ?? "missing")} | ${escapeCell(change.after ?? "missing")} |`);
    }
    lines.push("");
  }
  lines.push(`- Latest ACP schema release: ${current.protocol.latestRelease.tag}`);
  lines.push(`- Published wire versions: ${current.protocol.availableWireVersions.join(", ")}`);
  lines.push(`- Gateway-supported wire versions: ${config.supportedWireVersions.join(", ")}`);
  if (unsupported.length) {
    lines.push(`- Manual protocol review required for wire version(s): ${unsupported.join(", ")}`);
  }
  lines.push("", "Before merging: run installer, permission, elicitation, cancellation, resume, and large-result smoke tests.", "");
  return `${lines.join("\n")}\n`;
}

export function validateMonitorConfig(config) {
  if (config?.schemaVersion !== 1) throw new Error("Unsupported ACP monitor config version");
  if (!Array.isArray(config.supportedWireVersions)
    || !config.supportedWireVersions.length
    || !config.supportedWireVersions.every((version) => Number.isInteger(version) && version > 0)) {
    throw new Error("supportedWireVersions must be a non-empty positive integer array");
  }
  if (typeof config.watchAllRegistryAgents !== "boolean") {
    throw new Error("watchAllRegistryAgents must be a boolean");
  }
  if (!Array.isArray(config.watchedAgents)
    || !config.watchedAgents.length
    || !config.watchedAgents.every((id) => typeof id === "string" && id)) {
    throw new Error("watchedAgents must be a non-empty string array");
  }
  if (new Set(config.watchedAgents).size !== config.watchedAgents.length) {
    throw new Error("watchedAgents must not contain duplicates");
  }
  if (!config.managedNpmAdapters || typeof config.managedNpmAdapters !== "object" || Array.isArray(config.managedNpmAdapters)) {
    throw new Error("managedNpmAdapters must be an object");
  }
  for (const [agentId, packageName] of Object.entries(config.managedNpmAdapters)) {
    if (!config.watchedAgents.includes(agentId)) throw new Error(`managed npm adapter is not watched: ${agentId}`);
    if (!/^(?:@[a-z0-9._-]+\/)?[a-z0-9._-]+$/.test(packageName)) {
      throw new Error(`invalid managed npm package name: ${packageName}`);
    }
  }
  if (!/^[\w.-]+\/[\w.-]+$/.test(config.protocolRepository ?? "")) {
    throw new Error("protocolRepository must be an owner/repository value");
  }
}

export function validateSnapshot(snapshot, config) {
  if (snapshot?.schemaVersion !== 1) throw new Error("Unsupported ACP upstream snapshot version");
  if (!snapshot.protocol?.latestRelease?.tag
    || !snapshot.protocol.latestRelease.publishedAt
    || !/^https:\/\//.test(snapshot.protocol.latestRelease.url ?? "")
    || !Array.isArray(snapshot.protocol?.availableWireVersions)
    || !snapshot.protocol.availableWireVersions.length
    || !snapshot.protocol.availableWireVersions.every((version) => Number.isInteger(version) && version > 0)) {
    throw new Error("ACP protocol snapshot is incomplete");
  }
  if (typeof snapshot.registry?.documentVersion !== "string" || !snapshot.registry?.agents) {
    throw new Error("ACP registry snapshot is incomplete");
  }
  const snapshotAgentIds = Object.keys(snapshot.registry.agents);
  if (config.watchAllRegistryAgents && !snapshotAgentIds.length) {
    throw new Error("ACP registry snapshot contains no agents");
  }
  for (const id of new Set([...config.watchedAgents, ...snapshotAgentIds])) {
    if (typeof snapshot.registry.agents[id]?.version !== "string") {
      throw new Error(`ACP registry snapshot is missing ${id}`);
    }
    if (!snapshot.registry.agents[id].distribution || typeof snapshot.registry.agents[id].distribution !== "object") {
      throw new Error(`ACP registry snapshot distribution is missing ${id}`);
    }
  }
}

function parseArgs(argv) {
  const options = { ...defaults };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--update") options.update = true;
    else if (arg === "--validate") options.validate = true;
    else if (arg === "--report") options.reportPath = resolve(requireOptionValue(argv, ++index, arg));
    else if (arg === "--config") options.configPath = resolve(requireOptionValue(argv, ++index, arg));
    else if (arg === "--snapshot") options.snapshotPath = resolve(requireOptionValue(argv, ++index, arg));
    else throw new Error(`Unknown monitor option: ${arg}`);
  }
  if (options.update && options.validate) throw new Error("--update and --validate cannot be combined");
  return options;
}

function requireOptionValue(argv, index, option) {
  const value = argv[index];
  if (!value || value.startsWith("--")) throw new Error(`${option} requires a path`);
  return value;
}

async function fetchJson(url, { fetchImpl, headers = {}, maxBytes = 2 * 1024 * 1024, timeoutMs = 20_000 }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  timer.unref?.();
  try {
    const response = await fetchImpl(url, { headers, signal: controller.signal, redirect: "follow" });
    if (!response.ok) throw new Error(`${url} returned HTTP ${response.status}`);
    const text = await response.text();
    if (Buffer.byteLength(text) > maxBytes) throw new Error(`${url} response exceeds ${maxBytes} bytes`);
    return JSON.parse(text);
  } finally {
    clearTimeout(timer);
  }
}

function addChange(changes, component, before, after) {
  if (before !== after) changes.push({ component, before, after });
}

function sortObject(value) {
  if (Array.isArray(value)) return value.map(sortObject);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortObject(value[key])]));
}

function stableJson(value) {
  return JSON.stringify(sortObject(value));
}

function escapeCell(value) {
  return String(value).replaceAll("|", "\\|").replaceAll("\n", " ");
}
