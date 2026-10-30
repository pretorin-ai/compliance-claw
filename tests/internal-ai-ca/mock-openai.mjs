// mock-openai.mjs — a minimal OpenAI-compatible Chat Completions endpoint over
// HTTPS, for tests/internal-ai-ca/run.sh only. It holds no model and no secret.
//
// The first request that offers tools receives a tool call. A request that
// carries the matching tool result receives the final text. The log line for
// each request is the test evidence: it shows the tool round trip, not only a
// chat response.
import fs from "node:fs";
import https from "node:https";

const dir = process.env.MOCK_CERT_DIR;
const expectedKey = fs.readFileSync(process.env.MOCK_EXPECTED_KEY_FILE, "utf8").trim();
const FINAL_TEXT = "INTERNAL-AI-FIXTURE-TOOL-RESULT-RECEIVED";
const CALL_ID = "call_fixture_1";

function log(record) {
  process.stdout.write(`mock-openai ${JSON.stringify(record)}\n`);
}

function pickTool(tools) {
  const names = tools.map((tool) => tool?.function?.name).filter(Boolean);
  // Harmless read-only tools first. The fixture needs a real tool execution.
  for (const preferred of ["tool_search", "session_status", "tool_describe"]) {
    if (names.includes(preferred)) return preferred;
  }
  return names[0];
}

function argumentsFor(name) {
  if (name === "tool_search") return { query: "status" };
  return {};
}

function chunk(model, delta, finishReason = null) {
  return {
    id: "chatcmpl-fixture",
    object: "chat.completion.chunk",
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [{ index: 0, delta, finish_reason: finishReason }],
  };
}

function respond(res, body, message, finishReason) {
  const model = body.model ?? "fixture-model";
  if (body.stream) {
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(`data: ${JSON.stringify(chunk(model, { role: "assistant", ...message }))}\n\n`);
    res.write(`data: ${JSON.stringify(chunk(model, {}, finishReason))}\n\n`);
    res.write(
      `data: ${JSON.stringify({
        ...chunk(model, {}),
        choices: [],
        usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
      })}\n\n`,
    );
    res.end("data: [DONE]\n\n");
    return;
  }
  res.writeHead(200, { "content-type": "application/json" });
  res.end(
    JSON.stringify({
      id: "chatcmpl-fixture",
      object: "chat.completion",
      created: Math.floor(Date.now() / 1000),
      model,
      choices: [{ index: 0, message: { role: "assistant", ...message }, finish_reason: finishReason }],
      usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
    }),
  );
}

const server = https.createServer(
  {
    cert: fs.readFileSync(`${dir}/server.crt`),
    key: fs.readFileSync(`${dir}/server.key`),
  },
  (req, res) => {
    let raw = "";
    req.on("data", (part) => {
      raw += part;
    });
    req.on("end", () => {
      const path = req.url ?? "";
      if (req.headers.authorization !== `Bearer ${expectedKey}`) {
        log({ path, outcome: "rejected_auth" });
        res.writeHead(401, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: { message: "invalid fixture key" } }));
        return;
      }
      if (req.method === "GET" && path.endsWith("/models")) {
        log({ path, outcome: "models" });
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ object: "list", data: [{ id: "fixture-model", object: "model" }] }));
        return;
      }
      if (req.method !== "POST" || !path.endsWith("/chat/completions")) {
        log({ path, method: req.method, outcome: "not_found" });
        res.writeHead(404);
        res.end();
        return;
      }
      let body;
      try {
        body = JSON.parse(raw);
      } catch {
        res.writeHead(400);
        res.end();
        return;
      }
      const tools = Array.isArray(body.tools) ? body.tools : [];
      const messages = Array.isArray(body.messages) ? body.messages : [];
      // The runtime can normalize call IDs, so match the result to the ID that
      // the replayed assistant message carries, not to the literal sent.
      const callIds = new Set(
        messages
          .filter((m) => m?.role === "assistant" && Array.isArray(m.tool_calls))
          .flatMap((m) => m.tool_calls.map((call) => call?.id)),
      );
      const toolResult = messages.find((m) => m?.role === "tool" && callIds.has(m.tool_call_id));
      if (toolResult) {
        const content =
          typeof toolResult.content === "string" ? toolResult.content : JSON.stringify(toolResult.content);
        log({
          path,
          outcome: "final_after_tool_result",
          stream: Boolean(body.stream),
          toolResultBytes: content.length,
          requestKeys: Object.keys(body).sort(),
          messageRoles: messages.map((m) => m?.role),
          // An error result means the tool call did not run correctly.
          toolResultError: /"isError"\s*:\s*true|"status"\s*:\s*"error"|^\s*error\b/i.test(content),
        });
        respond(res, body, { content: FINAL_TEXT }, "stop");
        return;
      }
      const name = pickTool(tools);
      if (!name) {
        log({ path, outcome: "no_tools_offered", stream: Boolean(body.stream) });
        respond(res, body, { content: "INTERNAL-AI-FIXTURE-NO-TOOLS" }, "stop");
        return;
      }
      log({
        path,
        outcome: "tool_call",
        tool: name,
        toolsOffered: tools.length,
        stream: Boolean(body.stream),
        // Request shape only: field names, tool names and roles, no content.
        requestKeys: Object.keys(body).sort(),
        toolNames: tools.map((tool) => tool?.function?.name).filter(Boolean),
        messageRoles: messages.map((m) => m?.role),
      });
      const call = {
        id: CALL_ID,
        type: "function",
        function: { name, arguments: JSON.stringify(argumentsFor(name)) },
      };
      respond(
        res,
        body,
        { content: null, tool_calls: body.stream ? [{ index: 0, ...call }] : [call] },
        "tool_calls",
      );
    });
  },
);

server.on("tlsClientError", (error) => {
  log({ outcome: "tls_client_error", code: error.code ?? null, message: error.message });
});

server.listen(8443, "0.0.0.0", () => log({ outcome: "listening", certSet: process.env.MOCK_CERT_SET }));
