import Schema from '@deepseek-ai/schemastery';

export const PROVIDER = 'opencode-zen';
export const PUBLIC_BASE_URL = 'https://opencode.ai/zen/v1';
export const DEFAULT_API_KEY = 'public';

// Hardcoded free models (no dynamic catalog)
export const FREE_MODELS = [
  {
    id: 'deepseek-chat',
    name: 'DeepSeek Chat',
    contextWindow: 32768,
    maxTokens: 4096,
    reasoning: true,
  },
  {
    id: 'qwen-2.5-coder-32b-instruct',
    name: 'Qwen 2.5 Coder 32B',
    contextWindow: 131072,
    maxTokens: 8192,
    reasoning: false,
  },
  {
    id: 'deepseek-reasoner',
    name: 'DeepSeek Reasoner',
    contextWindow: 65536,
    maxTokens: 8192,
    reasoning: true,
  },
];

export function assertSafeBaseURL(value: any): string {
  const raw = String(value ?? '');
  let parsed;
  try {
    parsed = new URL(raw);
  } catch {
    throw new Error(`llm-opencode-zen: baseURL is not a valid URL: ${JSON.stringify(raw.slice(0, 80))}`);
  }
  const host = parsed.hostname;
  const isLoopback = host === 'localhost' || host === '127.0.0.1' || host === '[::1]' || host === '::1' || host.endsWith('.localhost');
  if (parsed.protocol !== 'https:' && !(parsed.protocol === 'http:' && isLoopback)) {
    throw new Error(`llm-opencode-zen: baseURL must use https (http allowed only for localhost), got ${parsed.protocol}//${host}`);
  }
  if (parsed.username || parsed.password) {
    throw new Error('llm-opencode-zen: baseURL must not contain userinfo (user:pass@) — use credential-ref for auth');
  }
  return raw;
}

export interface Config {
  apiKey?: string;
  baseURL?: string;
  providers?: string[];
  defaultModel?: string;
}

export const Config: Schema<Config> = Schema.object({
  apiKey: Schema.string().default(DEFAULT_API_KEY).description('OpenCode Zen API key (default: "public" for free models)'),
  baseURL: Schema.string().default(PUBLIC_BASE_URL).description('OpenCode Zen API endpoint'),
  providers: Schema.array(Schema.string()).default([PROVIDER]).description('Provider names this adapter handles'),
  defaultModel: Schema.string().default('deepseek-chat').description('Default model when none specified'),
});

export function resolveConfig(config: Config) {
  const baseURL = assertSafeBaseURL(config.baseURL ?? PUBLIC_BASE_URL);
  return {
    apiKey: config.apiKey ?? DEFAULT_API_KEY,
    baseURL,
    providers: config.providers ?? [PROVIDER],
    defaultModel: config.defaultModel ?? 'deepseek-chat',
  };
}
