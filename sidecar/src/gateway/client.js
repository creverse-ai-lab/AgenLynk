// The only Gateway code entrypoint used by the AgenLynk sidecar.
// Swift supplies the verified active runtime's public client path. The package
// that owns it names the specifier the client is published under:
// `acp-gateway-daemon/client` for the npm package (Gateway 1.7+, installed at
// runtime/versions/<id>/node_modules/acp-gateway-daemon), `acp-gateway/client`
// for a mounted runtime tarball (Gateway <= 1.6). The entrypoint must be the
// file that package's own `exports` map publishes as ./client.
import { readFile, realpath } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const CLIENT_SPECIFIERS = new Map([
  ["acp-gateway-daemon", "acp-gateway-daemon/client"],
  ["acp-gateway", "acp-gateway/client"]
]);

const entrypoint = process.env.ACP_GATEWAY_CLIENT_ENTRYPOINT;
if (!entrypoint) {
  throw new Error("ACP_GATEWAY_CLIENT_ENTRYPOINT must point to the active Gateway public client");
}
if (!entrypoint.endsWith("/gateway-client/index.js")) {
  throw new Error("ACP_GATEWAY_CLIENT_ENTRYPOINT is not the Gateway public client entrypoint");
}

export const GATEWAY_CLIENT_SPECIFIER = await clientSpecifier(dirname(dirname(entrypoint)), entrypoint);

const client = await import(pathToFileURL(entrypoint).href);
if (client.GATEWAY_API_VERSION !== 1 || typeof client.GatewayRpcClient !== "function") {
  throw new Error("Gateway public client is incompatible with AgenLynk 0.6.0");
}

export const {
  ERROR_CODES,
  GATEWAY_API_VERSION,
  GatewayError,
  GatewayRpcClient
} = client;

// Resolves `<name>/client` through the package's exports map by hand: the
// sidecar is not installed beside the package, so Node's own resolver cannot
// see it. A root without package.json (a test stub) is loaded as given.
async function clientSpecifier(packageRoot, file) {
  let packageJson;
  try {
    packageJson = JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw new Error(`Gateway package.json is unreadable: ${error.message}`);
  }
  const specifier = CLIENT_SPECIFIERS.get(packageJson?.name);
  if (!specifier) throw new Error(`${packageJson?.name ?? "unnamed package"} is not a Gateway package`);
  const exported = packageJson.exports?.["./client"];
  if (typeof exported !== "string" || !exported.startsWith("./")) {
    throw new Error(`${packageJson.name} does not export ./client`);
  }
  const [published, given] = await Promise.all([realpath(resolve(packageRoot, exported)), realpath(file)]);
  if (published !== given) throw new Error(`ACP_GATEWAY_CLIENT_ENTRYPOINT is not what ${specifier} resolves to`);
  return specifier;
}
