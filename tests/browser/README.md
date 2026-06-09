# Browser tests

Headless-Chrome integration tests for the LuCI singbox-ui builder.
Drive Puppeteer (host-side, via bun) against a containerised LuCI stack
(`tests/browser-container/`). The same `tests/test_browser.sh` runs
locally and in CI — one env, no drift.

## Run locally

```sh
bash tests/test_browser.sh
```

First run downloads:
- `~40 MB` of OpenWrt apk layer (cached by Docker)
- `~200 MB` of Chrome (cached in `~/.cache/puppeteer/`)
- Puppeteer + deps (cached in `tests/browser/node_modules/`)

Subsequent runs: ~2 minutes wall clock for the full 20-test matrix.

### Requirements

- `docker` (any moby ≥20)
- `bun` (≥1.2 — `curl -fsSL https://bun.sh/install | bash`)
- `bash` (the harness uses `#!/usr/bin/env bash` for `set -o pipefail`)

No `node`, no `npm`, no live OpenWrt VM needed.

## Adding a new test

Tests live in `tests/browser/[0-9]*.mjs`. Naming:
- `0x` — page-load / smoke
- `1x` — modal smoke per kind
- `2x` — UI mechanics (advanced toggle, conditional fields)
- `3x` — subscription / share-link
- `4x` — save-roundtrip
- `5x` — per-inbound matrix
- `6x` — per-outbound matrix

Each test imports from `_setup.mjs` and uses `runTest(name, fn)`.

```js
import { runTest, openAddModal, setProtocolInModal, fillField,
         saveAndReload, fetchPreviewConfig, assert } from './_setup.mjs';

await runTest('inbound:foo — smoke', async ({ page }) => {
    await openAddModal(page, 'inbound', 'foo_in');
    await setProtocolInModal(page, 'foo');
    await fillField(page, 'Listen port', '12345');
    await saveAndReload(page);
    const json = await fetchPreviewConfig(page);
    assert('foo emit', json.inbounds?.[0]?.type === 'foo');
});
```

## Debugging

Inspect the running container:

```sh
docker ps --filter name=singbox-ui-test
docker exec -it singbox-ui-test-<pid> sh
```

Force a fresh image build:

```sh
docker rmi luci-singbox-ui-browser:<hash>
```

Run a single test (the harness exports BROWSER_URL and DOCKER_NAME for in-process tests):

```sh
# After bash tests/test_browser.sh has started a container, you can pull
# the values from a running container:
CNAME=$(docker ps --filter name=singbox-ui-test --format '{{.Names}}' | head -1)
PORT=$(docker port "$CNAME" 80/tcp | head -1 | awk -F: '{print $NF}')
( cd tests/browser && BROWSER_URL=http://127.0.0.1:$PORT/cgi-bin/luci \
    DOCKER_NAME=$CNAME bun 54-inbound-vless.mjs )
```
