// src/index.ts
import {
  LlmAdapter,
  LlmError as LlmError2,
  attributionHeaders,
  ReasoningEffortId
} from "@deepseek-ai/dsh-llm";

// src/config.ts
import Schema from "@deepseek-ai/schemastery";
var PROVIDER = "opencode-zen";
var PUBLIC_BASE_URL = "https://opencode.ai/zen/v1";
var DEFAULT_API_KEY = "public";
var FREE_MODELS = [
  {
    id: "deepseek-chat",
    name: "DeepSeek Chat",
    contextWindow: 32768,
    maxTokens: 4096,
    reasoning: true
  },
  {
    id: "qwen-2.5-coder-32b-instruct",
    name: "Qwen 2.5 Coder 32B",
    contextWindow: 131072,
    maxTokens: 8192,
    reasoning: false
  },
  {
    id: "deepseek-reasoner",
    name: "DeepSeek Reasoner",
    contextWindow: 65536,
    maxTokens: 8192,
    reasoning: true
  }
];
function assertSafeBaseURL(value) {
  const raw = String(value ?? "");
  let parsed;
  try {
    parsed = new URL(raw);
  } catch {
    throw new Error(`llm-opencode-zen: baseURL is not a valid URL: ${JSON.stringify(raw.slice(0, 80))}`);
  }
  const host = parsed.hostname;
  const isLoopback = host === "localhost" || host === "127.0.0.1" || host === "[::1]" || host === "::1" || host.endsWith(".localhost");
  if (parsed.protocol !== "https:" && !(parsed.protocol === "http:" && isLoopback)) {
    throw new Error(`llm-opencode-zen: baseURL must use https (http allowed only for localhost), got ${parsed.protocol}//${host}`);
  }
  if (parsed.username || parsed.password) {
    throw new Error("llm-opencode-zen: baseURL must not contain userinfo (user:pass@) \u2014 use credential-ref for auth");
  }
  return raw;
}
var Config = Schema.object({
  apiKey: Schema.string().default(DEFAULT_API_KEY).description('OpenCode Zen API key (default: "public" for free models)'),
  baseURL: Schema.string().default(PUBLIC_BASE_URL).description("OpenCode Zen API endpoint"),
  providers: Schema.array(Schema.string()).default([PROVIDER]).description("Provider names this adapter handles"),
  defaultModel: Schema.string().default("deepseek-chat").description("Default model when none specified")
});
function resolveConfig(config) {
  const baseURL = assertSafeBaseURL(config.baseURL ?? PUBLIC_BASE_URL);
  return {
    apiKey: config.apiKey ?? DEFAULT_API_KEY,
    baseURL,
    providers: config.providers ?? [PROVIDER],
    defaultModel: config.defaultModel ?? "deepseek-chat"
  };
}

// src/serialize.ts
function flattenText(blocks) {
  return blocks.filter((b) => b.type === "text").map((b) => b.text).join("");
}
function serializeAssistant(message) {
  const content = message.content || [];
  const text = flattenText(content);
  const reasoning = content.filter((b) => b.type === "reasoning").map((b) => b.text).join("");
  const toolCalls = content.filter((b) => b.type === "tool-call").map((b) => ({
    id: b.id,
    type: "function",
    function: { name: b.name, arguments: b.arguments }
  }));
  return {
    role: "assistant",
    content: text,
    ...reasoning.length > 0 ? { reasoning_content: reasoning } : {},
    ...toolCalls.length > 0 ? { tool_calls: toolCalls } : {}
  };
}
function serializeMessages(messages) {
  const wire = [];
  for (const message of messages) {
    const content = message.content || [];
    if (message.role === "system") {
      wire.push({ role: "system", content: flattenText(content) });
      continue;
    }
    if (message.role === "assistant") {
      wire.push(serializeAssistant(message));
      continue;
    }
    const toolResults = content.filter((b) => b.type === "tool-result");
    const text = flattenText(content);
    if (text.length > 0 || toolResults.length === 0) {
      wire.push({ role: "user", content: text });
    }
    for (const result of toolResults) {
      const resultContent = result.content || [];
      wire.push({
        role: "tool",
        tool_call_id: result.toolCallId || "",
        content: flattenText(resultContent) || "(no output)"
      });
    }
  }
  return wire;
}
function serializeTools(tools) {
  if (!tools || tools.length === 0) return void 0;
  return tools.map((tool) => ({
    type: "function",
    function: {
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters
    }
  }));
}
function buildRequestPayload(model, messages, tools, reasoningEffort, maxTokens, temperature, stop) {
  return {
    model,
    messages,
    stream: true,
    stream_options: { include_usage: true },
    max_tokens: maxTokens,
    top_p: 0.95,
    ...temperature !== void 0 ? { temperature } : {},
    ...stop && stop.length > 0 ? { stop } : {},
    ...tools ? { tools, tool_choice: "auto" } : {},
    ...reasoningEffort && reasoningEffort !== "off" ? { reasoning_effort: reasoningEffort } : {}
  };
}

// src/stream.ts
import { LlmError } from "@deepseek-ai/dsh-llm";
import { EventSourceParserStream } from "eventsource-parser/stream";
var DONE = "[DONE]";
function estimateTokens(text) {
  return Math.ceil(text.length / 4);
}
function repairJSON(text) {
  try {
    JSON.parse(text);
    return { ok: true, text };
  } catch {
  }
  let result = text;
  let inString = false;
  let escaped = false;
  const stack = [];
  for (const ch of text) {
    if (inString) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch === "\\") {
        escaped = true;
        continue;
      }
      if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') {
      inString = true;
      continue;
    }
    if (ch === "{" || ch === "[") {
      stack.push(ch === "{" ? "}" : "]");
      continue;
    }
    if (ch === "}" || ch === "]") {
      if (stack[stack.length - 1] === ch) stack.pop();
    }
  }
  if (inString) result += '"';
  while (stack.length > 0) result += stack.pop();
  try {
    JSON.parse(result);
    return { ok: true, text: result };
  } catch {
    return { ok: false, text };
  }
}
async function* parseSSE(stream, onComment) {
  const events = stream.pipeThrough(new TextDecoderStream()).pipeThrough(new EventSourceParserStream({ onComment }));
  const reader = events.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        throw new LlmError("SSE stream ended without [DONE]", "STREAM_CLOSED");
      }
      yield value.data;
      if (value.data === DONE) return;
    }
  } finally {
    reader.releaseLock();
  }
}
async function* translateToChunks(events, estimateInput) {
  let nextIndex = 0;
  let textBlock = null;
  let reasoningBlock = null;
  const toolBlocks = /* @__PURE__ */ new Map();
  const order = [];
  let pendingFinish = null;
  let pendingUsage = null;
  const openBlock = (kind) => {
    const block = { index: nextIndex++, kind, text: "" };
    order.push(block);
    return block;
  };
  const closeBlock = (block) => {
    switch (block.kind) {
      case "text":
        return { type: "text", text: block.text };
      case "reasoning":
        return { type: "reasoning", text: block.text };
      case "tool-call":
        return {
          type: "tool-call",
          id: block.callId ?? "",
          name: block.name ?? "",
          arguments: block.text
        };
    }
  };
  const estimateUsage = () => {
    const inputText = estimateInput();
    let outputText = textBlock?.text ?? "";
    for (const block of order) {
      if (block.kind === "tool-call") outputText += block.text;
    }
    const reasoningText = reasoningBlock?.text ?? "";
    return {
      inputTokens: estimateTokens(inputText),
      outputTokens: estimateTokens(outputText),
      ...reasoningText ? { reasoningTokens: Math.min(estimateTokens(reasoningText), estimateTokens(outputText)) } : {}
    };
  };
  for await (const payload of events) {
    if (payload === DONE) {
      let malformed = false;
      for (const block of order) {
        if (block.kind === "tool-call") {
          const repair = repairJSON(block.text);
          if (repair.ok) {
            block.text = repair.text;
          } else {
            malformed = true;
          }
        }
        yield { type: "block-end", index: block.index, block: closeBlock(block) };
      }
      yield {
        type: "usage",
        usage: pendingUsage ?? estimateUsage()
      };
      let reason = pendingFinish ?? { kind: "stop" };
      if (malformed) {
        reason = {
          kind: "error",
          failure: {
            message: "OpenCode Zen returned tool arguments that are not valid JSON",
            code: "TOOL_ARGS_MALFORMED"
          }
        };
      } else if (reason.kind === "stop" && order.length === 0) {
        reason = {
          kind: "error",
          failure: { message: "model returned a completed response with no content", code: "EMPTY_RESPONSE" }
        };
      }
      yield { type: "finish", reason };
      return;
    }
    let chunk;
    try {
      chunk = JSON.parse(payload);
    } catch {
      throw new LlmError(`malformed SSE payload: ${payload.slice(0, 120)}`, "MALFORMED_RESPONSE");
    }
    for (const choice of chunk.choices ?? []) {
      const delta = choice.delta;
      const reasoning = delta?.reasoning_content;
      if (typeof reasoning === "string" && reasoning.length > 0) {
        if (!reasoningBlock) {
          reasoningBlock = openBlock("reasoning");
          yield { type: "block-start", index: reasoningBlock.index, blockType: "reasoning" };
        }
        reasoningBlock.text += reasoning;
        yield { type: "reasoning-delta", index: reasoningBlock.index, text: reasoning };
      }
      const content = delta?.content;
      if (typeof content === "string" && content.length > 0) {
        if (!textBlock) {
          textBlock = openBlock("text");
          yield { type: "block-start", index: textBlock.index, blockType: "text" };
        }
        textBlock.text += content;
        yield { type: "text-delta", index: textBlock.index, text: content };
      }
      for (const call of delta?.tool_calls ?? []) {
        let block = toolBlocks.get(call.index);
        if (!block) {
          block = openBlock("tool-call");
          toolBlocks.set(call.index, block);
          yield { type: "block-start", index: block.index, blockType: "tool-call" };
        }
        if (call.id !== void 0 && call.id !== null) block.callId = call.id;
        if (call.function?.name !== void 0 && call.function?.name !== null) block.name = call.function.name;
        const fragment = call.function?.arguments ?? "";
        block.text += fragment;
        yield {
          type: "tool-call-delta",
          index: block.index,
          id: block.callId ?? "",
          ...block.name !== void 0 ? { name: block.name } : {},
          argumentsDelta: fragment
        };
      }
      if (typeof choice.finish_reason === "string") {
        switch (choice.finish_reason) {
          case "stop":
            pendingFinish = { kind: "stop" };
            break;
          case "tool_calls":
            pendingFinish = { kind: "tool-calls" };
            break;
          case "length":
            pendingFinish = { kind: "max-tokens" };
            break;
          default: {
            const code = choice.finish_reason === "network_error" ? "TRANSPORT" : choice.finish_reason.toUpperCase();
            pendingFinish = {
              kind: "error",
              failure: { message: `model stopped: ${choice.finish_reason}`, code }
            };
          }
        }
      }
    }
    if (chunk.usage) {
      const usage = chunk.usage;
      const cacheRead = usage.prompt_tokens_details?.cached_tokens ?? usage.prompt_cache_hit_tokens;
      const reasoning = usage.completion_tokens_details?.reasoning_tokens;
      pendingUsage = {
        inputTokens: usage.prompt_tokens - (cacheRead ?? 0),
        outputTokens: usage.completion_tokens,
        ...cacheRead !== void 0 ? { cacheReadTokens: cacheRead } : {},
        ...reasoning !== void 0 ? { reasoningTokens: reasoning } : {}
      };
    }
  }
  throw new LlmError("SSE payload stream ended without [DONE]", "STREAM_CLOSED");
}

// src/index.ts
var OpenCodeZenAdapter = class extends LlmAdapter {
  config;
  constructor(config) {
    super();
    this.config = config;
  }
  async *stream(options) {
    const messages = serializeMessages(options.messages);
    const tools = serializeTools(options.tools);
    let reasoningEffort = options.reasoningEffort;
    if (options.purpose === "session-title") {
      reasoningEffort = "off";
    }
    const maxTokens = options.purpose === "session-title" ? Math.min(options.maxTokens || 4096, 64) : options.maxTokens || 4096;
    const payload = buildRequestPayload(
      options.model,
      messages,
      tools,
      reasoningEffort,
      maxTokens,
      options.temperature,
      options.stop
    );
    const response = await fetch(`${this.config.baseURL}/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${this.config.apiKey}`,
        "User-Agent": "dsh-pwa/opencode-zen-lite",
        ...attributionHeaders()
      },
      body: JSON.stringify(payload),
      signal: options.signal
    });
    if (!response.ok) {
      const errorText = await response.text().catch(() => "");
      let code = "PROVIDER_ERROR";
      if (response.status === 401 || response.status === 403) {
        code = "AUTH";
      } else if (response.status === 429) {
        code = "RATE_LIMITED";
      } else if (response.status >= 500) {
        code = "PROVIDER_ERROR";
      }
      throw new LlmError2(
        `OpenCode Zen API error: ${response.status} ${errorText.slice(0, 200)}`,
        code
      );
    }
    if (!response.body) {
      throw new LlmError2("No response body", "PROVIDER_ERROR");
    }
    const events = parseSSE(response.body);
    const estimateInput = () => {
      return messages.map(
        (m) => typeof m.content === "string" ? m.content : ""
      ).join("\n");
    };
    yield* translateToChunks(events, estimateInput);
  }
  async resolveModel(provider, model, _signal) {
    const modelConfig = FREE_MODELS.find((m) => m.id === model);
    const reasoning = modelConfig?.reasoning !== false ? {
      efforts: [
        { id: ReasoningEffortId("off"), name: "Off", description: "No chain-of-thought; fastest responses" },
        { id: ReasoningEffortId("low"), name: "Low", description: "Light reasoning for quick tasks" },
        { id: ReasoningEffortId("high"), name: "High", description: "Balanced reasoning for everyday work" },
        { id: ReasoningEffortId("max"), name: "Max", description: "Deep reasoning; slowest but most thorough" }
      ],
      defaultEffort: ReasoningEffortId("high")
    } : {
      efforts: [{ id: ReasoningEffortId("off"), name: "Off", description: "No chain-of-thought" }],
      defaultEffort: ReasoningEffortId("off")
    };
    return {
      provider,
      id: model,
      name: modelConfig?.name ?? model,
      inputModalities: ["text"],
      context: {
        contextWindow: modelConfig?.contextWindow ?? 32768
      },
      defaultMaxTokens: modelConfig?.maxTokens ?? 4096,
      reasoning
    };
  }
  async listModels(provider) {
    const defaultModel = this.config.defaultModel;
    const sorted = [...FREE_MODELS].sort((a, b) => {
      if (a.id === defaultModel) return -1;
      if (b.id === defaultModel) return 1;
      return a.name.localeCompare(b.name);
    });
    return sorted.map((model) => ({
      provider,
      id: model.id,
      name: model.name,
      inputModalities: ["text"]
    }));
  }
};
var name = "llm-opencode-zen";
var inject = ["llm"];
function apply(ctx, config) {
  const resolved = resolveConfig(config);
  const adapter = new OpenCodeZenAdapter(resolved);
  ctx.llm.registerAdapter(resolved.providers, adapter);
  ctx.logger?.info(`[llm-opencode-zen] Registered adapter for providers: ${resolved.providers.join(", ")}`);
  ctx.logger?.info(`[llm-opencode-zen] Base URL: ${resolved.baseURL}`);
  ctx.logger?.info(`[llm-opencode-zen] Free models: ${FREE_MODELS.map((m) => m.id).join(", ")}`);
}
export {
  Config,
  FREE_MODELS,
  PROVIDER,
  apply,
  inject,
  name
};
