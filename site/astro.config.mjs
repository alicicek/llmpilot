// @ts-check
import { defineConfig } from "astro/config";
import react from "@astrojs/react";
import sitemap from "@astrojs/sitemap";
import tailwindcss from "@tailwindcss/vite";

// Static output (default) — the landing is fully static; interactive bits are
// client-hydrated islands. The Pro checkout POSTs to the separate llmpilot-api
// Worker, so no Astro SSR/adapter is needed. Deploy: wrangler pages deploy dist/
export default defineConfig({
  site: "https://llmpilot.dev",
  integrations: [
    react(),
    sitemap({
      // checkout/recovery utility pages — noindex, keep them out of the sitemap
      filter: (page) =>
        !["/pro/activated/", "/pro/declined/", "/recover/"].some((p) =>
          page.endsWith(p),
        ),
    }),
  ],
  vite: {
    plugins: [tailwindcss()],
  },
});
