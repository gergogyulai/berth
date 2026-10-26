import { defineConfig } from "astro/config";

export default defineConfig({
  // Lets the dev server answer requests proxied through `tailscale serve`.
  vite: { server: { allowedHosts: [".ts.net"] } },
});
