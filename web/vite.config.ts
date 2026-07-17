import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Dev-only: proxy /v1 to the running daemon so `pnpm dev` talks to real state.
// The embedded production build is same-origin and needs no proxy.
function daemonPort(): string {
  try {
    const home = process.env.LLMPILOT_HOME ?? join(homedir(), ".llmpilot");
    return readFileSync(join(home, "daemon.port"), "utf8").trim();
  } catch {
    return "0";
  }
}

export default defineConfig({
  plugins: [react(), tailwindcss()],
  base: "./",
  server: {
    proxy: {
      "/v1": { target: `http://127.0.0.1:${daemonPort()}` },
    },
  },
});
