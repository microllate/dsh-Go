import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequestCapture } from "../bridge/dsh-go-bridge/lib/request-capture.js";

test("capture saves only the first armed request and preserves its JSON bytes", async t => {
  const downloads = await mkdtemp(join(tmpdir(), "dsh-request-capture-"));
  t.after(() => rm(downloads, { recursive: true, force: true }));
  const capture = createRequestCapture(downloads);
  await capture.capture("{}");
  assert.deepEqual(await readdir(downloads), []);
  const body = '{"messages":[{"role":"user","content":"你好"}],"tools":[]}';
  capture.setArmed(true);
  await Promise.all([capture.capture(body), capture.capture("{}")]);
  const files = await readdir(join(downloads, "DSH-Go"));
  assert.equal(files.length, 1);
  assert.equal(await readFile(join(downloads, "DSH-Go", files[0]), "utf8"), body);
  assert.deepEqual(capture.status(), {
    armed: false, saving: false, failed: false, file: "Download/DSH-Go/" + files[0],
  });
});

test("failed writes leave the one-shot capture armed", async t => {
  const root = await mkdtemp(join(tmpdir(), "dsh-request-capture-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const downloads = join(root, "Download");
  await writeFile(downloads, "blocks directory creation");
  const capture = createRequestCapture(downloads);
  capture.setArmed(true);
  await capture.capture("{}");
  assert.deepEqual(capture.status(), { armed: true, saving: false, failed: true, file: null });
  await rm(downloads);
  await mkdir(downloads);
  await capture.capture("{}");
  assert.equal(capture.status().armed, false);
  assert.equal(capture.status().failed, false);
});
