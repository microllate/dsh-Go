import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { join } from "node:path";

export const requestCaptureHook = Symbol.for("dsh-go.capture-model-request");

export function createRequestCapture(downloads = "/sdcard/Download") {
  let armed = false;
  let saving = false;
  let failed = false;
  let file = null;

  return {
    status: () => ({ armed, saving, failed, file }),
    setArmed(value) {
      if (saving) return false;
      armed = value;
      failed = false;
      if (value) file = null;
      return true;
    },
    async capture(body) {
      if (!armed || saving || typeof body !== "string") return;
      saving = true;
      const dir = join(downloads, "DSH-Go");
      const name = `model-request-${Date.now()}-${randomUUID()}.json`;
      const temp = join(dir, `.${name}.tmp`);
      try {
        await mkdir(dir).catch(error => {
          if (error.code !== "EEXIST") throw error;
        });
        await writeFile(temp, body, { flag: "wx", mode: 0o600 });
        await rename(temp, join(dir, name));
        file = `Download/DSH-Go/${name}`;
        armed = false;
        failed = false;
      } catch {
        failed = true;
        await rm(temp, { force: true }).catch(() => {});
      } finally {
        saving = false;
      }
    },
  };
}
