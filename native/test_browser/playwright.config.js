import {defineConfig} from '@playwright/test';
import {fileURLToPath} from 'node:url';
const cwd = fileURLToPath(new URL('../../', import.meta.url));
export default defineConfig({
  testDir: '.', testMatch: '*.spec.js', timeout: 45000, workers: 1,
  use: {baseURL: 'http://127.0.0.1:4280', headless: true, trace: 'retain-on-failure', screenshot: 'only-on-failure'},
  webServer: [
    {cwd, command: 'python3 -m http.server 4280 --bind 127.0.0.1 --directory native/build/browser-test', url: 'http://127.0.0.1:4280'},
    {cwd, command: 'node native/test_browser/peer-server.cjs', url: 'http://127.0.0.1:9000/peerjs'},
  ],
});
