import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequestUsage } from "../bridge/dsh-go-bridge/lib/request-usage.js";

test("provider usage survives reopening and advances a stable read offset", async t => {
  const root = await mkdtemp(join(tmpdir(), "dsh-request-usage-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const path = join(root, "usage.jsonl");
  const first = createRequestUsage(path);
  assert.deepEqual(first.read(0), { offset: 0, records: [] });
  const request = {
    time: 1795560000000,
    model: "deepseek-flash",
    usage: { inputTokens: 15, cacheReadTokens: 90, cacheWriteTokens: 2, outputTokens: 4 },
  };
  first.record(request);
  const second = createRequestUsage(path);
  const page = second.read(0);
  assert.equal(page.records.length, 1);
  assert.deepEqual(page.records[0].slice(1), [request.time, request.model, 90, 17, 4]);
  assert.deepEqual(second.read(page.offset), { offset: page.offset, records: [] });
  second.record({ ...request, settled: true });
  const next = first.read(page.offset);
  assert.equal(next.records.length, 1);
  assert.match(next.records[0][0], /^v2:/);
  assert.doesNotMatch(page.records[0][0], /^v2:/);
  assert.deepEqual(next.records[0].slice(1), page.records[0].slice(1));
});
