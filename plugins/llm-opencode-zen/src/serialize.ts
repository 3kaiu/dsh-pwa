import type { Message } from '@deepseek-ai/dsh-llm';

interface Tool {
  name: string;
  description?: string;
  parameters?: any;
}

function flattenText(blocks: any[]): string {
  return blocks.filter((b: any) => b.type === 'text').map((b: any) => b.text).join('');
}

function serializeAssistant(message: Message) {
  const content = message.content || [];
  const text = flattenText(content);
  const reasoning = content.filter((b: any) => b.type === 'reasoning').map((b: any) => b.text).join('');
  const toolCalls = content
    .filter((b: any) => b.type === 'tool-call')
    .map((b: any) => ({
      id: b.id,
      type: 'function' as const,
      function: { name: b.name, arguments: b.arguments },
    }));

  return {
    role: 'assistant' as const,
    content: text,
    ...(reasoning.length > 0 ? { reasoning_content: reasoning } : {}),
    ...(toolCalls.length > 0 ? { tool_calls: toolCalls } : {}),
  };
}

export function serializeMessages(messages: Message[]) {
  const wire: any[] = [];
  for (const message of messages) {
    const content = message.content || [];
    
    if (message.role === 'system') {
      wire.push({ role: 'system', content: flattenText(content) });
      continue;
    }
    
    if (message.role === 'assistant') {
      wire.push(serializeAssistant(message));
      continue;
    }
    
    // User role: handle text + tool results
    const toolResults = content.filter((b: any) => b.type === 'tool-result');
    const text = flattenText(content);
    
    if (text.length > 0 || toolResults.length === 0) {
      wire.push({ role: 'user', content: text });
    }
    
    for (const result of toolResults) {
      const resultContent = (result as any).content || [];
      wire.push({
        role: 'tool',
        tool_call_id: (result as any).toolCallId || '',
        content: flattenText(resultContent) || '(no output)',
      });
    }
  }
  return wire;
}

export function serializeTools(tools?: Tool[]) {
  if (!tools || tools.length === 0) return undefined;
  return tools.map((tool) => ({
    type: 'function' as const,
    function: {
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters,
    },
  }));
}

export function buildRequestPayload(
  model: string,
  messages: any[],
  tools: any[] | undefined,
  reasoningEffort: string | undefined,
  maxTokens: number,
  temperature?: number,
  stop?: string[]
) {
  return {
    model,
    messages,
    stream: true,
    stream_options: { include_usage: true },
    max_tokens: maxTokens,
    top_p: 0.95,
    ...(temperature !== undefined ? { temperature } : {}),
    ...(stop && stop.length > 0 ? { stop } : {}),
    ...(tools ? { tools, tool_choice: 'auto' } : {}),
    ...(reasoningEffort && reasoningEffort !== 'off' ? { reasoning_effort: reasoningEffort } : {}),
  };
}
