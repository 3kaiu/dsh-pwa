import { LlmError } from '@deepseek-ai/dsh-llm';
import { EventSourceParserStream } from 'eventsource-parser/stream';

const DONE = '[DONE]';

// Simplified token estimation (no complex CJK detection)
function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

// Repair malformed tool call JSON
function repairJSON(text: string): { ok: boolean; text: string } {
  try {
    JSON.parse(text);
    return { ok: true, text };
  } catch {}
  
  // Try closing brackets
  let result = text;
  let inString = false;
  let escaped = false;
  const stack: string[] = [];
  
  for (const ch of text) {
    if (inString) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch === '\\') {
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
    if (ch === '{' || ch === '[') {
      stack.push(ch === '{' ? '}' : ']');
      continue;
    }
    if (ch === '}' || ch === ']') {
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

export async function* parseSSE(
  stream: ReadableStream<Uint8Array>,
  onComment?: (comment: string) => void
): AsyncIterable<string> {
  // @ts-ignore - TextDecoderStream type mismatch with ReadableStream
  const events = stream
    .pipeThrough(new TextDecoderStream())
    .pipeThrough(new EventSourceParserStream({ onComment }));
  
  const reader = events.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        throw new LlmError('SSE stream ended without [DONE]', 'STREAM_CLOSED');
      }
      yield value.data;
      if (value.data === DONE) return;
    }
  } finally {
    reader.releaseLock();
  }
}

export async function* translateToChunks(
  events: AsyncIterable<string>,
  estimateInput: () => string
): AsyncIterable<any> {
  let nextIndex = 0;
  let textBlock: any = null;
  let reasoningBlock: any = null;
  const toolBlocks = new Map<number, any>();
  const order: any[] = [];
  let pendingFinish: any = null;
  let pendingUsage: any = null;
  
  const openBlock = (kind: string) => {
    const block = { index: nextIndex++, kind, text: '' };
    order.push(block);
    return block;
  };
  
  const closeBlock = (block: any) => {
    switch (block.kind) {
      case 'text':
        return { type: 'text', text: block.text };
      case 'reasoning':
        return { type: 'reasoning', text: block.text };
      case 'tool-call':
        return {
          type: 'tool-call',
          id: block.callId ?? '',
          name: block.name ?? '',
          arguments: block.text,
        };
    }
  };
  
  const estimateUsage = () => {
    const inputText = estimateInput();
    let outputText = textBlock?.text ?? '';
    for (const block of order) {
      if (block.kind === 'tool-call') outputText += block.text;
    }
    const reasoningText = reasoningBlock?.text ?? '';
    
    return {
      inputTokens: estimateTokens(inputText),
      outputTokens: estimateTokens(outputText),
      ...(reasoningText ? { reasoningTokens: Math.min(estimateTokens(reasoningText), estimateTokens(outputText)) } : {}),
    };
  };
  
  for await (const payload of events) {
    if (payload === DONE) {
      // Repair tool call JSON
      let malformed = false;
      for (const block of order) {
        if (block.kind === 'tool-call') {
          const repair = repairJSON(block.text);
          if (repair.ok) {
            block.text = repair.text;
          } else {
            malformed = true;
          }
        }
        yield { type: 'block-end', index: block.index, block: closeBlock(block) };
      }
      
      yield {
        type: 'usage',
        usage: pendingUsage ?? estimateUsage(),
      };
      
      let reason = pendingFinish ?? { kind: 'stop' };
      if (malformed) {
        reason = {
          kind: 'error',
          failure: {
            message: 'OpenCode Zen returned tool arguments that are not valid JSON',
            code: 'TOOL_ARGS_MALFORMED',
          },
        };
      } else if (reason.kind === 'stop' && order.length === 0) {
        reason = {
          kind: 'error',
          failure: { message: 'model returned a completed response with no content', code: 'EMPTY_RESPONSE' },
        };
      }
      
      yield { type: 'finish', reason };
      return;
    }
    
    let chunk;
    try {
      chunk = JSON.parse(payload);
    } catch {
      throw new LlmError(`malformed SSE payload: ${payload.slice(0, 120)}`, 'MALFORMED_RESPONSE');
    }
    
    for (const choice of chunk.choices ?? []) {
      const delta = choice.delta;
      
      // Reasoning content
      const reasoning = delta?.reasoning_content;
      if (typeof reasoning === 'string' && reasoning.length > 0) {
        if (!reasoningBlock) {
          reasoningBlock = openBlock('reasoning');
          yield { type: 'block-start', index: reasoningBlock.index, blockType: 'reasoning' };
        }
        reasoningBlock.text += reasoning;
        yield { type: 'reasoning-delta', index: reasoningBlock.index, text: reasoning };
      }
      
      // Text content
      const content = delta?.content;
      if (typeof content === 'string' && content.length > 0) {
        if (!textBlock) {
          textBlock = openBlock('text');
          yield { type: 'block-start', index: textBlock.index, blockType: 'text' };
        }
        textBlock.text += content;
        yield { type: 'text-delta', index: textBlock.index, text: content };
      }
      
      // Tool calls
      for (const call of delta?.tool_calls ?? []) {
        let block = toolBlocks.get(call.index);
        if (!block) {
          block = openBlock('tool-call');
          toolBlocks.set(call.index, block);
          yield { type: 'block-start', index: block.index, blockType: 'tool-call' };
        }
        if (call.id !== undefined && call.id !== null) block.callId = call.id;
        if (call.function?.name !== undefined && call.function?.name !== null) block.name = call.function.name;
        const fragment = call.function?.arguments ?? '';
        block.text += fragment;
        yield {
          type: 'tool-call-delta',
          index: block.index,
          id: block.callId ?? '',
          ...(block.name !== undefined ? { name: block.name } : {}),
          argumentsDelta: fragment,
        };
      }
      
      // Finish reason
      if (typeof choice.finish_reason === 'string') {
        switch (choice.finish_reason) {
          case 'stop':
            pendingFinish = { kind: 'stop' };
            break;
          case 'tool_calls':
            pendingFinish = { kind: 'tool-calls' };
            break;
          case 'length':
            pendingFinish = { kind: 'max-tokens' };
            break;
          default: {
            const code = choice.finish_reason === 'network_error' ? 'TRANSPORT' : choice.finish_reason.toUpperCase();
            pendingFinish = {
              kind: 'error',
              failure: { message: `model stopped: ${choice.finish_reason}`, code },
            };
          }
        }
      }
    }
    
    // Usage
    if (chunk.usage) {
      const usage = chunk.usage;
      const cacheRead = usage.prompt_tokens_details?.cached_tokens ?? usage.prompt_cache_hit_tokens;
      const reasoning = usage.completion_tokens_details?.reasoning_tokens;
      pendingUsage = {
        inputTokens: usage.prompt_tokens - (cacheRead ?? 0),
        outputTokens: usage.completion_tokens,
        ...(cacheRead !== undefined ? { cacheReadTokens: cacheRead } : {}),
        ...(reasoning !== undefined ? { reasoningTokens: reasoning } : {}),
      };
    }
  }
  
  throw new LlmError('SSE payload stream ended without [DONE]', 'STREAM_CLOSED');
}
