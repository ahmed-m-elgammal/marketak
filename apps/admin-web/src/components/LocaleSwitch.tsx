/**
 * `components/LocaleSwitch` - switching between English and Arabic.
 *
 * ## Why it also flips the document direction
 *
 * Arabic is not an English layout with Arabic glyphs. `applyDocumentLocale` sets `document.documentElement.dir`,
 * which is what makes the whole tree mirror: the sidebar moves to the right, the table columns reverse, and
 * antd's own components read `direction` from `ConfigProvider` and flip their popups accordingly.
 *
 * Without the `dir` attribute an Arabic console renders left-to-right, and an operator reads a mirrored
 * layout as corrupt data rather than as a styling fault - which sends them to the wrong person.
 */

import { Segmented } from "antd";
import type { ReactElement } from "react";
import { useTranslation } from "react-i18next";

import { applyDocumentLocale, SUPPORTED_LOCALES, type Locale } from "../i18n/index.js";

/** Each language labelled in itself, so an operator who cannot read the current one can still find theirs. */
const SELF_LABEL: Readonly<Record<Locale, string>> = {
  en: "English",
  ar: "العربية",
};

export function LocaleSwitch(): ReactElement {
  const { t, i18n: instance } = useTranslation();
  const active = instance.language.split("-")[0] ?? "en";

  return (
    <Segmented<Locale>
      aria-label={t("app.language")}
      value={SUPPORTED_LOCALES.find((locale) => locale === active) ?? "en"}
      options={SUPPORTED_LOCALES.map((locale) => ({
        label: SELF_LABEL[locale],
        value: locale,
      }))}
      onChange={(next) => {
        void instance.changeLanguage(next).then(() => {
          applyDocumentLocale(next, document);
        });
      }}
    />
  );
}