import type { NextConfig } from "next";

// The API (api/, Express) is a separate process. In development the site
// forwards /auth/* and /api/* to it, so the browser still sees one origin
// and the session cookie needs no CORS:
//
//   node api/server.js     # http://localhost:4000
//   npm run dev            # http://localhost:3000
//
// API_ORIGIN overrides the address. On Vercel none of this applies:
// vercel.json routes /api/* and /auth/* to the API function before a
// request reaches the site, so a production build forwards nothing unless
// API_ORIGIN is set explicitly.
const api = (process.env.API_ORIGIN
  ?? (process.env.NODE_ENV === "production" ? undefined : "http://localhost:4000"))?.replace(/\/$/, "");

const nextConfig: NextConfig = {
  async redirects() {
    // Links to the old static pages (x.html) keep working.
    return [
      { source: "/index.html", destination: "/", permanent: true },
      { source: "/:page([a-z-]+)\\.html", destination: "/:page", permanent: true },
    ];
  },
  async rewrites() {
    if (!api) return [];
    return [
      { source: "/auth/:path*", destination: `${api}/auth/:path*` },
      { source: "/api/:path*", destination: `${api}/api/:path*` },
    ];
  },
};

export default nextConfig;
