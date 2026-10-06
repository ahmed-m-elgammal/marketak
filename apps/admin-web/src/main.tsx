/**
 * `main.tsx` - the entry point.
 *
 * ## Why the locale is resolved before `createRoot`
 *
 * An Arabic console that paints once in English and then switches is a flash of wrong content, and on a
 * tablet that reads as a page reload. The browser's language is read and applied to `<html>` **before** React
 * mounts, so the first paint already has `lang`, `dir` and the right strings.
 *
 * ## StrictMode is deliberate
 *
 * It double-invokes render in development, which is how the double `<style>`-injection bug in
 * `providers.tsx` was caught before it shipped. The cost is development-only.
 *
 * ## Why the import of the stylesheet is last
 *
 * `global.css` holds the `--space-*` fallbacks, and antd's own CSS-in-JS resolves the colour custom
 * properties. Importing the stylesheet before the providers mount would leave the variables undefined for
 * the first frame.
 */

import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";

import { App } from "./app/App.js";
import { Providers } from "./app/providers.js";
import i18n, { applyDocumentLocale, detectLocale } from "./i18n/index.js";

import "./app/styles/global.css";

async function start(): Promise<void> {
  const locale = detectLocale(typeof navigator === "undefined" ? undefined : navigator.language);

  applyDocumentLocale(locale, document);
  await i18n.changeLanguage(locale);

  const container = document.getElementById("root");
  if (container === null) {
    // Thrown, not returned. A silent return renders a blank page with nothing in the console, which is far
    // harder to diagnose from a bug report than a thrown error naming the missing element.
    throw new Error("#root is missing from index.html");
  }

  createRoot(container).render(
    <StrictMode>
      <BrowserRouter>
        <Providers locale={locale}>
          <App />
        </Providers>
      </BrowserRouter>
    </StrictMode>,
  );
}

void start();