import { appendFileSync, mkdirSync, openSync, readSync, closeSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const requestUsageHook = Symbol.for("dsh-go.record-model-usage");

export function createRequestUsage(path = join(homedir(), ".dsh", "dsh-go", "request-usage-v1.jsonl")) {
  return {
    record({ time, model, usage }) {
      const hit = usage.cacheReadTokens ?? 0;
      const miss = usage.inputTokens + (usage.cacheWriteTokens ?? 0);
      const out = usage.outputTokens;
      if (![hit, miss, out].every(n => Number.isSafeInteger(n) && n >= 0) || hit + miss + out === 0) return;
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      appendFileSync(path, JSON.stringify([randomUUID(), time, model, hit, miss, out]) + "\n", { mode: 0o600 });
    },
    read(offset) {
      let fd;
      try {
        fd = openSync(path, "r");
      } catch (error) {
        if (error.code === "ENOENT") return { offset: 0, records: [] };
        throw error;
      }
      try {
        const buffer = Buffer.alloc(64 * 1024);
        const length = readSync(fd, buffer, 0, buffer.length, offset);
        const end = buffer.subarray(0, length).lastIndexOf(10) + 1;
        const records = [];
        for (const line of buffer.toString("utf8", 0, end).split("\n")) {
          if (!line) continue;
          try {
            records.push(JSON.parse(line));
          } catch {
            // A torn final write must not hide later requests.
          }
        }
        return { offset: offset + end, records };
      } finally {
        closeSync(fd);
      }
    },
  };
}
