/**
 * The i18n home (mobile README §1, L5). One import point for strings,
 * language objects, plurals, bidi isolation, label treatment and direction.
 */
export { pickLang, type LangString } from "./pickLang";
export { BIDI_OPEN, BIDI_CLOSE, isolateBidi } from "./bidi";
export { labelTreatment, type LabelTreatment } from "./labels";
export { arabicPluralCategory, pluralKey, fillCount, type ArabicPluralCategory } from "./plurals";
export { resolveLanguage, applyRtlPolicy, type RtlManager } from "./language";
export { useT, translate, type Translator } from "./useT";
