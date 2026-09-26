import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { EVENT_KINDS, EVENT_SOURCES, EVENT_STATUSES, SESSION_STATUSES, USAGE_FIELDS } from "../sidecar/src/normalize/model.js";

const schemaUrl = new URL("../contracts/monitor/v2/monitor-snapshot.schema.json", import.meta.url);
const fixtureUrl = new URL("../sidecar/test/fixtures/monitor-snapshot-v2.json", import.meta.url);

// Dependency-free validator for the JSON Schema subset this contract uses
// (type, const, enum, required, properties, additionalProperties as false or
// a schema, items, oneOf, minItems, minimum, maxLength, local $ref).
function validate(schema, value, root = schema, path = "$") {
  if (schema.$ref) return validate(root.$defs[schema.$ref.replace("#/$defs/", "")], value, root, path);
  if (schema.oneOf) {
    const matches = schema.oneOf.filter((option) => {
      try {
        validate(option, value, root, path);
        return true;
      } catch {
        return false;
      }
    });
    assert.equal(matches.length, 1, `${path} must match exactly one schema`);
    return;
  }
  if (schema.const !== undefined) assert.deepEqual(value, schema.const, `${path} must equal ${JSON.stringify(schema.const)}`);
  if (schema.enum) assert.ok(schema.enum.includes(value), `${path} ${JSON.stringify(value)} not in ${JSON.stringify(schema.enum)}`);
  if (schema.type) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    const actual = value === null ? "null" : Array.isArray(value) ? "array"
      : typeof value === "number" ? (Number.isInteger(value) ? "integer" : "number") : typeof value;
    assert.ok(types.includes(actual) || (actual === "integer" && types.includes("number")), `${path} type ${actual} not in ${types}`);
  }
  if (schema.minimum !== undefined && typeof value === "number") assert.ok(value >= schema.minimum, `${path} < ${schema.minimum}`);
  if (schema.maxLength !== undefined && typeof value === "string") assert.ok(value.length <= schema.maxLength, `${path} too long`);
  if (schema.format === "date-time" && typeof value === "string") assert.ok(!Number.isNaN(Date.parse(value)), `${path} is not a date-time`);
  if (value && typeof value === "object" && !Array.isArray(value) && (schema.properties || schema.additionalProperties !== undefined)) {
    for (const key of schema.required ?? []) assert.ok(Object.hasOwn(value, key), `${path} is missing "${key}"`);
    for (const [key, item] of Object.entries(value)) {
      if (schema.properties?.[key]) validate(schema.properties[key], item, root, `${path}.${key}`);
      else if (schema.additionalProperties === false) assert.fail(`${path} has unexpected property "${key}"`);
      else if (schema.additionalProperties && typeof schema.additionalProperties === "object") {
        validate(schema.additionalProperties, item, root, `${path}.${key}`);
      }
    }
  }
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined) assert.ok(value.length >= schema.minItems, `${path} has too few items`);
    if (schema.items) value.forEach((item, index) => validate(schema.items, item, root, `${path}[${index}]`));
  }
}

test("the v2 snapshot fixture satisfies the monitor contract", async () => {
  const schema = JSON.parse(await readFile(schemaUrl, "utf8"));
  const fixture = JSON.parse(await readFile(fixtureUrl, "utf8"));
  const { _comment, _input, ...snapshot } = fixture;
  validate(schema, snapshot);
  assert.ok(Object.values(snapshot.events).flat().length > 2, "the fixture exercises several events");
});

test("the contract vocabulary is exactly the normalizer's", async () => {
  const schema = JSON.parse(await readFile(schemaUrl, "utf8"));
  const event = schema.$defs.event.properties;
  assert.deepEqual(event.kind.enum, EVENT_KINDS);
  assert.deepEqual(event.status.enum.filter((value) => value !== null), EVENT_STATUSES);
  assert.deepEqual(event.sources.items.enum, EVENT_SOURCES);
  assert.deepEqual(schema.$defs.session.properties.status.enum, SESSION_STATUSES);
  assert.deepEqual(schema.$defs.usage.required, USAGE_FIELDS);
});
