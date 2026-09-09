# OpenCode Zen LLM Adapter for DeepSeek Harness

**Lightweight, modernized adapter for OpenCode Zen free models, designed for `dsh@next`.**

## Features

- ✅ Support for OpenCode Zen free models (`deepseek-chat`, `qwen-2.5-coder-32b-instruct`, etc.)
- ✅ SSE streaming with automatic JSON repair for tool calls
- ✅ Reasoning mode support (off/low/high/max)
- ✅ Simplified token estimation (no complex CJK detection)
- ❌ No dynamic catalog (hardcoded model list)
- ❌ No browser UI
- ❌ No local quota tracking

## Installation

```bash
cd ~/.dsh
pnpm add file:/path/to/dsh-pwa/plugins/llm-opencode-zen
```

## Configuration

Add to your `cordis.yml`:

```yaml
- id: opencode-zen
  name: '@dsh-pwa/llm-opencode-zen'
  config:
    apiKey: public  # or your OpenCode API key
    baseURL: https://opencode.ai/zen/v1
    providers:
      - opencode-zen
    defaultModel: deepseek-chat
```

## Supported Models

| Model ID | Name | Context Window | Max Tokens | Reasoning |
|----------|------|----------------|------------|-----------|
| `deepseek-chat` | DeepSeek Chat | 32,768 | 4,096 | ✅ |
| `qwen-2.5-coder-32b-instruct` | Qwen 2.5 Coder 32B | 131,072 | 8,192 | ❌ |
| `deepseek-reasoner` | DeepSeek Reasoner | 65,536 | 8,192 | ✅ |

To add more models, edit `src/config.ts:FREE_MODELS`.

## Code Size

- **Total:** ~660 lines (vs 1,600 in original)
- **src/config.ts:** 80 lines
- **src/serialize.ts:** 109 lines
- **src/stream.ts:** 250 lines
- **src/index.ts:** 200 lines

## Differences from Original

| Feature | Original v0.4.0 | This Version |
|---------|----------------|--------------|
| Dependencies | 10+ packages | 4 packages |
| Code size | 1,600 lines | 660 lines |
| Dynamic catalog | ✅ | ❌ (hardcoded) |
| Browser UI | ✅ | ❌ |
| Quota tracking | ✅ | ❌ |
| Pacing limiter | ✅ | ❌ (rely on dsh retry) |
| dsh version | 0.1.0-rc.7 | 0.1.2-rc.1 (next) |

## License

MIT
