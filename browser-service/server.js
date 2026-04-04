// browser-service/server.js
// Tiny HTTP server that uses Playwright to fetch JavaScript-rendered pages.
// Ballerina calls this for known SPA domains that reject plain HTTP requests.
//
// Setup:
//   npm install playwright express
//   npx playwright install chromium
//   node server.js
//
// Usage:
//   GET http://localhost:3456/fetch?url=https://developers.zoom.us/docs/api/meetings/
//
// Returns JSON:
//   { "html": "<rendered HTML content>" }
//   { "error": "error message" }

const express = require("express");
const { chromium } = require("playwright");

const app = express();
const PORT = 3456;

let browser = null;

// Launch browser once on startup
async function getBrowser() {
  if (!browser) {
    browser = await chromium.launch({
      headless: true,
      args: [
        "--no-sandbox",
        "--disable-setuid-sandbox",
        "--disable-dev-shm-usage",
        "--disable-gpu",
      ],
    });
  }
  return browser;
}

app.get("/fetch", async (req, res) => {
  const url = req.query.url;
  if (!url) {
    return res.status(400).json({ error: "url parameter required" });
  }

  console.log(`[browser-fetch] ${url}`);

  let page = null;
  try {
    const b = await getBrowser();
    const context = await b.newContext({
      userAgent:
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      extraHTTPHeaders: {
        Accept:
          "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.5",
      },
    });

    page = await context.newPage();

    // Navigate and wait for network to settle
    await page.goto(url, {
      waitUntil: "networkidle",
      timeout: 30000,
    });

    // Extra wait for JS-heavy pages to finish rendering
    await page.waitForTimeout(2000);

    const html = await page.content();
    await context.close();

    console.log(`[browser-fetch] OK — ${html.length} bytes`);
    res.json({ html });
  } catch (err) {
    console.error(`[browser-fetch] ERROR: ${err.message}`);
    if (page) {
      try {
        await page.close();
      } catch (_) {}
    }
    res.status(500).json({ error: err.message });
  }
});

// Health check
app.get("/health", (_, res) => res.json({ status: "ok" }));

app.listen(PORT, async () => {
  console.log(`Browser service listening on http://localhost:${PORT}`);
  // Pre-warm the browser
  try {
    await getBrowser();
    console.log("Chromium ready");
  } catch (err) {
    console.error("Failed to launch browser:", err.message);
  }
});

// Graceful shutdown
process.on("SIGTERM", async () => {
  if (browser) await browser.close();
  process.exit(0);
});
