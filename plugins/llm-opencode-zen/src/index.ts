import type { Context } from '@deepseek-ai/cordis';
import { 
  LlmAdapter, 
  LlmError, 
  attributionHeaders, 
  ReasoningEffortId,
  type GenerateOptions, 
  type StreamChunk,
  type LlmResolvedModelInfo 
} from '@deepseek-ai/dsh-llm';
import { PROVIDER, Config, FREE_MODELS, resolveConfig } from './config.js';
import { serializeMessages, serializeTools, buildRequestPayload } from './serialize.js';
import { parseSSE, translateToChunks } from './stream.js';

class OpenCodeZenAdapter extends LlmAdapter {
  private config: ReturnType<typeof resolveConfig>;

  constructor(config: ReturnType<typeof resolveConfig>) {
    super();
    this.config = config;
  }

  async *stream(options: GenerateOptions): AsyncIterable<StreamChunk> {
    const messages = serializeMessages(options.messages);
    const tools = serializeTools(options.tools);
    
    // Determine reasoning effort
    let reasoningEffort: string | undefined = options.reasoningEffort;
    if (options.purpose === 'session-title') {
      reasoningEffort = 'off';
    }
    
    const maxTokens = options.purpose === 'session-title' 
      ? Math.min(options.maxTokens || 4096, 64)
      : (options.maxTokens || 4096);
    
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
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${this.config.apiKey}`,
        'User-Agent': 'dsh-pwa/opencode-zen-lite',
        ...attributionHeaders(),
      },
      body: JSON.stringify(payload),
      signal: options.signal,
    });
    
    if (!response.ok) {
      const errorText = await response.text().catch(() => '');
      let code = 'PROVIDER_ERROR';
      if (response.status === 401 || response.status === 403) {
        code = 'AUTH';
      } else if (response.status === 429) {
        code = 'RATE_LIMITED';
      } else if (response.status >= 500) {
        code = 'PROVIDER_ERROR';
      }
      throw new LlmError(
        `OpenCode Zen API error: ${response.status} ${errorText.slice(0, 200)}`,
        code
      );
    }
    
    if (!response.body) {
      throw new LlmError('No response body', 'PROVIDER_ERROR');
    }
    
    const events = parseSSE(response.body);
    const estimateInput = () => {
      return messages.map((m: any) => 
        typeof m.content === 'string' ? m.content : ''
      ).join('\n');
    };
    
    yield* translateToChunks(events, estimateInput);
  }

  async resolveModel(provider: string, model: string, _signal?: AbortSignal): Promise<LlmResolvedModelInfo> {
    const modelConfig = FREE_MODELS.find(m => m.id === model);
    
    const reasoning = modelConfig?.reasoning !== false ? {
      efforts: [
        { id: ReasoningEffortId('off'), name: 'Off', description: 'No chain-of-thought; fastest responses' },
        { id: ReasoningEffortId('low'), name: 'Low', description: 'Light reasoning for quick tasks' },
        { id: ReasoningEffortId('high'), name: 'High', description: 'Balanced reasoning for everyday work' },
        { id: ReasoningEffortId('max'), name: 'Max', description: 'Deep reasoning; slowest but most thorough' },
      ] as const,
      defaultEffort: ReasoningEffortId('high'),
    } : {
      efforts: [{ id: ReasoningEffortId('off'), name: 'Off', description: 'No chain-of-thought' }] as const,
      defaultEffort: ReasoningEffortId('off'),
    };
    
    return {
      provider,
      id: model,
      name: modelConfig?.name ?? model,
      inputModalities: ['text' as const],
      context: {
        contextWindow: modelConfig?.contextWindow ?? 32768,
      },
      defaultMaxTokens: modelConfig?.maxTokens ?? 4096,
      reasoning,
    };
  }

  async listModels(provider: string) {
    const defaultModel = this.config.defaultModel;
    
    // Sort: default model first, then alphabetically
    const sorted = [...FREE_MODELS].sort((a, b) => {
      if (a.id === defaultModel) return -1;
      if (b.id === defaultModel) return 1;
      return a.name.localeCompare(b.name);
    });
    
    return sorted.map(model => ({
      provider,
      id: model.id,
      name: model.name,
      inputModalities: ['text' as const],
    }));
  }
}

export const name = 'llm-opencode-zen';
export const inject = ['llm'];

export function apply(ctx: Context, config: Config) {
  const resolved = resolveConfig(config);
  const adapter = new OpenCodeZenAdapter(resolved);
  
  ctx.llm.registerAdapter(resolved.providers, adapter);
  
  ctx.logger?.info(`[llm-opencode-zen] Registered adapter for providers: ${resolved.providers.join(', ')}`);
  ctx.logger?.info(`[llm-opencode-zen] Base URL: ${resolved.baseURL}`);
  ctx.logger?.info(`[llm-opencode-zen] Free models: ${FREE_MODELS.map(m => m.id).join(', ')}`);
}

export { Config, PROVIDER, FREE_MODELS };
