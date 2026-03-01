#!/usr/bin/env node

const fs = require("node:fs");
const path = require("node:path");
const minimist = require("minimist");
const puppeteer = require("puppeteer-core");

/** @typedef {'load'|'domcontentloaded'|'networkidle0'|'networkidle2'} WaitUntil */

/**
 * @param {string} message
 */
function fail(message) {
  process.stderr.write(`Error: ${message}\n`);
  process.exit(1);
}

/**
 * @param {string} value
 * @returns {boolean}
 */
function hasTraversal(value) {
  const parts = value.split("/");
  return parts.includes("..");
}

/**
 * @param {unknown} value
 * @param {number} fallback
 * @returns {number}
 */
function parseInteger(value, fallback) {
  if (typeof value === "number" && Number.isFinite(value))
    return Math.floor(value);
  if (typeof value === "string" && value.trim().length > 0) {
    const parsed = Number.parseInt(value, 10);
    if (Number.isFinite(parsed)) return parsed;
  }
  return fallback;
}

/**
 * @param {unknown} value
 * @returns {WaitUntil}
 */
function parseWaitUntil(value) {
  if (typeof value !== "string") return "networkidle2";
  if (
    value === "load" ||
    value === "domcontentloaded" ||
    value === "networkidle0" ||
    value === "networkidle2"
  ) {
    return value;
  }
  fail(
    "Invalid --wait-until. Use load|domcontentloaded|networkidle0|networkidle2",
  );
}

async function main() {
  const args = minimist(process.argv.slice(2), {
    string: ["url", "output", "browser", "wait-until"],
    boolean: ["full-page", "help"],
    default: {
      "full-page": true,
      "wait-until": "networkidle2",
      width: 1920,
      height: 1080,
      "delay-ms": 500,
      headless: true,
    },
  });

  if (args.help) {
    process.stdout.write(
      [
        "capture.js",
        "",
        "Required:",
        "  --url <url>",
        "  --output <path-within-repo>",
        "  --browser <path-to-chromium>",
        "",
        "Optional:",
        "  --width <number> (default 1920)",
        "  --height <number> (default 1080)",
        "  --wait-until <load|domcontentloaded|networkidle0|networkidle2> (default networkidle2)",
        "  --delay-ms <number> (default 500)",
        "  --full-page <true|false> (default true)",
      ].join("\n") + "\n",
    );
    return;
  }

  const url = typeof args.url === "string" ? args.url.trim() : "";
  const output = typeof args.output === "string" ? args.output.trim() : "";
  const browserPath =
    typeof args.browser === "string" ? args.browser.trim() : "";

  if (url.length === 0) fail("Missing --url");
  if (output.length === 0) fail("Missing --output");
  if (browserPath.length === 0) fail("Missing --browser");

  if (path.isAbsolute(output)) {
    fail("Output path must be relative to repo");
  }
  if (hasTraversal(output)) {
    fail("Output path cannot contain '..'");
  }

  const width = parseInteger(args.width, 1920);
  const height = parseInteger(args.height, 1080);
  const delayMs = parseInteger(args["delay-ms"], 500);
  const waitUntil = parseWaitUntil(args["wait-until"]);
  const fullPage = Boolean(args["full-page"]);

  const outputPath = path.resolve(process.cwd(), output);
  const outputDir = path.dirname(outputPath);
  fs.mkdirSync(outputDir, { recursive: true });

  const browser = await puppeteer.launch({
    executablePath: browserPath,
    headless: true,
    args: ["--no-sandbox", "--disable-setuid-sandbox"],
  });

  try {
    const page = await browser.newPage();
    await page.setViewport({ width, height });
    await page.goto(url, { waitUntil });
    if (delayMs > 0) {
      await page.waitForTimeout(delayMs);
    }
    await page.screenshot({ path: outputPath, fullPage });
    process.stdout.write(`Saved screenshot: ${output}\n`);
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  fail(message);
});
