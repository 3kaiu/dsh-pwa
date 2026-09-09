import { build } from 'esbuild';

await build({
  bundle: true,
  format: 'esm',
  platform: 'node',
  target: 'node20',
  minify: false,
  legalComments: 'none',
  entryPoints: ['src/index.ts'],
  outfile: 'dist/index.js',
  external: [
    '@deepseek-ai/dsh-llm',
    '@deepseek-ai/cordis',
    '@deepseek-ai/schemastery',
    'eventsource-parser'
  ],
});

console.log('✓ Built dist/index.js');
