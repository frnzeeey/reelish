import { defineConfig } from 'vitest/config';
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-pool-workers';

// Tests run inside workerd with a local D1 that has every migration applied.
const key = (fill: number) => Buffer.alloc(32, fill).toString('base64');

export default defineConfig({
  plugins: [
    cloudflareTest(async () => ({
      wrangler: { configPath: './wrangler.toml' },
      miniflare: {
        bindings: {
          TEST_MIGRATIONS: await readD1Migrations('migrations'),
          TMDB_READ_TOKEN: 'test-tmdb-read-token',
          TRAKT_CLIENT_ID: 'test-trakt-client-id',
          TRAKT_CLIENT_SECRET: 'test-trakt-client-secret',
          SESSION_SIGNING_KEY: key(1),
          TOKEN_ENCRYPTION_KEY: key(2),
        },
      },
    })),
  ],
  test: { setupFiles: ['./test/setup.ts'] },
});
