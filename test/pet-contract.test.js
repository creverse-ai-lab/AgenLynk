import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const CONTRACT_DIR = fileURLToPath(new URL("../contracts/pet/v1/", import.meta.url));

async function readJSON(name) {
  return JSON.parse(await readFile(join(CONTRACT_DIR, name), "utf8"));
}

// A tiny, dependency-free validator for the subset of JSON Schema draft
// 2020-12 the pet contracts actually use: type, const, enum, required,
// properties, additionalProperties, items, $ref (to local $defs), and a
// simple date-time/pattern format check. This is not a general-purpose
// schema validator — it only needs to prove our own schemas and examples
// agree, without pulling in a new dependency.
function validate(schema, value, root = schema, path = "$") {
  if (schema.$ref) {
    const defName = schema.$ref.replace("#/$defs/", "");
    return validate(root.$defs[defName], value, root, path);
  }
  if (schema.const !== undefined) {
    assert.equal(value, schema.const, `${path} must equal ${JSON.stringify(schema.const)}`);
  }
  if (schema.enum) {
    assert.ok(schema.enum.includes(value), `${path} value ${JSON.stringify(value)} must be one of ${JSON.stringify(schema.enum)}`);
  }
  if (schema.type) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    const actual = value === null ? "null" : Array.isArray(value) ? "array" : typeof value === "number" ? (Number.isInteger(value) ? "integer" : "number") : typeof value;
    const matches = types.includes(actual) || (actual === "integer" && types.includes("number"));
    assert.ok(matches, `${path} type ${actual} must be one of ${JSON.stringify(types)}`);
  }
  if (schema.pattern && typeof value === "string") {
    assert.ok(new RegExp(schema.pattern).test(value), `${path} value ${JSON.stringify(value)} must match ${schema.pattern}`);
  }
  if (schema.format === "date-time" && typeof value === "string") {
    assert.ok(!Number.isNaN(Date.parse(value)), `${path} must be a valid date-time string`);
  }
  if (schema.maxLength !== undefined && typeof value === "string") {
    assert.ok(value.length <= schema.maxLength, `${path} must be at most ${schema.maxLength} characters`);
  }
  if (schema.minimum !== undefined && typeof value === "number") {
    assert.ok(value >= schema.minimum, `${path} must be >= ${schema.minimum}`);
  }
  if (schema.type === "object" || (value !== null && typeof value === "object" && !Array.isArray(value) && schema.properties)) {
    for (const key of schema.required ?? []) {
      assert.ok(Object.hasOwn(value, key), `${path} is missing required property "${key}"`);
    }
    for (const [key, propertyValue] of Object.entries(value)) {
      const propertySchema = schema.properties?.[key];
      if (propertySchema) {
        validate(propertySchema, propertyValue, root, `${path}.${key}`);
      } else if (schema.additionalProperties === false) {
        assert.fail(`${path} has unexpected property "${key}"`);
      }
    }
  }
  if (schema.type === "array" && Array.isArray(value) && schema.items) {
    value.forEach((item, index) => validate(schema.items, item, root, `${path}[${index}]`));
  }
}

const CONTRACTS = [
  {
    name: "pet-state",
    schema: "pet-state.schema.json",
    minimum: "pet-state.example.minimum.json",
    full: "pet-state.example.full.json",
    listKey: "agents"
  },
  {
    name: "pet-actions",
    schema: "pet-actions.schema.json",
    minimum: "pet-actions.example.minimum.json",
    full: "pet-actions.example.full.json",
    listKey: "actions"
  }
];

for (const contract of CONTRACTS) {
  test(`${contract.name} schema declares the versioned envelope and is valid JSON Schema draft 2020-12`, async () => {
    const schema = await readJSON(contract.schema);
    assert.equal(schema.$schema, "https://json-schema.org/draft/2020-12/schema");
    assert.deepEqual(schema.required, ["contract", "version", "generatedAt", "producer", "sequence", contract.listKey]);
    assert.equal(schema.properties.contract.const, contract.name);
    assert.equal(schema.additionalProperties, false);
  });

  test(`${contract.name} minimum example satisfies the schema`, async () => {
    const schema = await readJSON(contract.schema);
    const example = await readJSON(contract.minimum);
    validate(schema, example);
    assert.deepEqual(example[contract.listKey], [], "the minimum example should carry no entries");
  });

  test(`${contract.name} full example satisfies the schema and exercises multiple entries`, async () => {
    const schema = await readJSON(contract.schema);
    const example = await readJSON(contract.full);
    validate(schema, example);
    assert.ok(example[contract.listKey].length > 1, "the full example should exercise more than one entry");
  });
}

test("pet-state enum is exactly the frozen contract vocabulary", async () => {
  const schema = await readJSON("pet-state.schema.json");
  assert.deepEqual(schema.$defs.agent.properties.state.enum, [
    "offline", "idle", "starting", "running", "waiting", "completed", "failed", "unknown"
  ]);
});

test("pet-actions enum is exactly the frozen contract vocabulary", async () => {
  const schema = await readJSON("pet-actions.schema.json");
  assert.deepEqual(schema.$defs.action.properties.action.enum, [
    "sleep", "wake", "think", "useTool", "waitForUser", "celebrate", "error", "disconnect", "unknown"
  ]);
});

test("pet-state and pet-actions full examples describe the same agent ids and parent linkage", async () => {
  const state = await readJSON("pet-state.example.full.json");
  const actions = await readJSON("pet-actions.example.full.json");
  const stateIds = state.agents.map((agent) => [agent.id, agent.parentId]);
  const actionIds = actions.actions.map((action) => [action.id, action.parentId]);
  assert.deepEqual(actionIds, stateIds, "pet-actions.json must describe the same agents/parent linkage as pet-state.json");
});

test("pet contract examples never carry prompt-, token-, or environment-shaped fields", async () => {
  for (const contract of CONTRACTS) {
    for (const file of [contract.minimum, contract.full]) {
      const raw = await readFile(join(CONTRACT_DIR, file), "utf8");
      assert.doesNotMatch(raw.toLowerCase(), /token|apikey|api_key|prompt|secret|environ/, `${file} must not carry private data`);
    }
  }
});
