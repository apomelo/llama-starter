/*
 * Schema-simplifying reverse proxy for llama.cpp (Claude Code / Codex friendly)
 * ---------------------------------------------------------------------------
 * Problem: Claude Code sends tools whose JSON Schemas contain heavy constraints
 * (minimum/maximum, minItems/maxItems, minLength/maxLength, pattern, ...).
 * llama.cpp turns those into a GBNF grammar that explodes and fails with:
 *     "error parsing grammar: number of repetitions exceeds sane defaults"
 *
 * This proxy sits in front of llama-server and recursively strips those
 * constraint keywords from every tool schema (and response_format json_schema)
 * BEFORE forwarding, so the generated grammar stays small while tool calling
 * keeps working. Responses (including SSE streams) are piped through untouched.
 *
 * Usage:
 *     node schema-proxy.js                 # listen 9998 -> forward 127.0.0.1:9999
 *     node schema-proxy.js 9998 9999       # <listen> <target>
 * Then point clients at the proxy:
 *     Claude Code:  ANTHROPIC_BASE_URL = http://localhost:9998
 *     Codex:        base_url           = http://localhost:9998/v1
 *
 * Zero dependencies (Node's built-in http only).
 */

"use strict";
const http = require("http");

const LISTEN_PORT = parseInt(process.argv[2], 10) || 9998;
const TARGET_PORT = parseInt(process.argv[3], 10) || 9999;
const TARGET_HOST = process.argv[4] || "127.0.0.1";

// JSON-Schema keywords that blow up GBNF grammar generation.
const STRIP_KEYS = new Set([
    "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
    "minItems", "maxItems", "minLength", "maxLength", "pattern",
    "minProperties", "maxProperties", "minContains", "maxContains", "format"
]);

// Recursively delete the offending constraint keywords.
function simplify(node) {
    if (Array.isArray(node)) {
        for (const item of node) simplify(item);
        return;
    }
    if (node && typeof node === "object") {
        for (const key of Object.keys(node)) {
            if (STRIP_KEYS.has(key)) {
                delete node[key];
            } else {
                simplify(node[key]);
            }
        }
    }
}

// Strip constraints from every tool schema + response_format schema in a body.
function processBody(obj) {
    if (!obj || typeof obj !== "object") return obj;

    if (Array.isArray(obj.tools)) {
        for (const tool of obj.tools) {
            if (!tool || typeof tool !== "object") continue;
            if (tool.input_schema) simplify(tool.input_schema);                 // Anthropic
            if (tool.function && tool.function.parameters) simplify(tool.function.parameters); // OpenAI
            if (tool.parameters) simplify(tool.parameters);                     // some variants
        }
    }
    if (obj.response_format && obj.response_format.json_schema && obj.response_format.json_schema.schema) {
        simplify(obj.response_format.json_schema.schema);                       // structured output
    }
    return obj;
}

const server = http.createServer((clientReq, clientRes) => {
    const chunks = [];
    clientReq.on("data", (c) => chunks.push(c));
    clientReq.on("end", () => {
        let bodyBuf = Buffer.concat(chunks);

        // Try to rewrite JSON bodies; on any failure, forward the original bytes.
        const ctype = String(clientReq.headers["content-type"] || "");
        if (bodyBuf.length > 0 && ctype.includes("application/json")) {
            try {
                const parsed = JSON.parse(bodyBuf.toString("utf8"));
                processBody(parsed);
                bodyBuf = Buffer.from(JSON.stringify(parsed), "utf8");
            } catch (_e) {
                /* not valid JSON – forward as-is */
            }
        }

        const headers = Object.assign({}, clientReq.headers);
        headers["host"] = `${TARGET_HOST}:${TARGET_PORT}`;
        headers["content-length"] = Buffer.byteLength(bodyBuf);

        const proxyReq = http.request(
            { host: TARGET_HOST, port: TARGET_PORT, method: clientReq.method, path: clientReq.url, headers },
            (proxyRes) => {
                clientRes.writeHead(proxyRes.statusCode, proxyRes.headers);
                proxyRes.pipe(clientRes); // stream response (supports SSE)
            }
        );

        proxyReq.on("error", (err) => {
            clientRes.writeHead(502, { "content-type": "text/plain" });
            clientRes.end("proxy error: " + err.message);
        });

        proxyReq.end(bodyBuf);
    });
});

server.listen(LISTEN_PORT, () => {
    console.log(`schema-proxy listening on http://127.0.0.1:${LISTEN_PORT}  ->  http://${TARGET_HOST}:${TARGET_PORT}`);
    console.log(`stripping schema keys: ${[...STRIP_KEYS].join(", ")}`);
});
