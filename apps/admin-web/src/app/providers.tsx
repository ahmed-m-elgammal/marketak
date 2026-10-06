/**
 * `app/providers` - the single place the app's context is composed.
 *
 * ## Why everything is mounted here
 *
 * `ConfigProvider`, the locale, the query client and the Supabase client are all created once, at the root.
 * That is not tidiness. `theme/antd-theme.ts` is the only place an antd `ThemeConfig` is constructed, and
 * this is the only place it is mounted - so a component physically cannot reach antd's default colours by
 * rendering outside this tree.
 *
 * ## antd locale packs are imported statically
 *
 * `ar_EG` and `en_US` would both land in the main chunk otherwise, and antd's combined locale bundle is
 * large. They are small individually, so the cost of importing both is lower than the complexity of loading
 * them on demand, and an operator switching language mid-session must not see a flash of English.
 */

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { App as AntdApp, ConfigProvider } from "antd";
import arEG from "antd/locale/ar_EG";
import enUS from "antd/locale/en_US";
import { useEffect, useMemo, type ReactNode } from "react";
import { I18nextProvider } from "react-i18next";

import { buildAntdConfig, cssVariablesBlock } from "@marketak/ui";

import i18nInstance, { antdLocaleKeyFor, type Locale } from "../i18n/index.js";

/** antd's locale packs, keyed by the same `Locale` union the rest of the app uses. */
const ANTD_LOCALES: Readonly<Record<Locale, typeof enUS>> = {
  en: enUS,
  ar: arEG,
};

/**
 * The one React Query client.
 *
 * `staleTime: 30_000` because this is an internal tool on a good connection: an operator switching between a
 * list and a profile should not refetch data they just loaded. `refetchOnWindowFocus` is **off** for the
 * same reason - a support agent with six tabs open would otherwise issue six queries every time they
 * alt-tabbed.
 *
 * `retry: 1` rather than 3. Three retries against a database that raised `CHECK_VIOLATION` means the same
 * failure three times, and the operator waits 7 seconds to be told something that will not change.
 */
function createQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 30_000,
        refetchOnWindowFocus: false,
        retry: 1,
      },
      mutations: {
        retry: 0,
      },
    },
  });
}

/**
 * Injects the `:root` custom properties.
 *
 * antd 6 resolves its own tokens through CSS variables, so this block is what lets a plain CSS rule in a
 * component reference `--color-text-primary` and agree with antd's rendering. Emitted once, imperatively,
 * rather than as a CSS file, so the values come from the same `colors.ts` that produced the antd theme -
 * two copies of a palette is the failure this whole module exists to prevent.
 */
function useInjectedCssVariables(): void {
  const block = useMemo(() => cssVariablesBlock(), []);
  // `useEffect`, not `useMemo`. A memo is for computing a value; this appends to `document.head`, and doing
  // it during render means the side effect fires on a render React may throw away - which in StrictMode
  // happens twice on mount.
  useEffect(() => {
    if (typeof document === "undefined") {
      return;
    }
    const id = "marketak-theme-vars";
    const existing = document.getElementById(id);
    const element = existing ?? document.createElement("style");
    element.id = id;
    element.textContent = block;
    if (existing === null) {
      document.head.appendChild(element);
    }
  }, [block]);
}

export interface ProvidersProps {
  readonly children: ReactNode;
  readonly locale: Locale;
}

export function Providers({ children, locale }: ProvidersProps): ReactNode {
  useInjectedCssVariables();

  const queryClient = useMemo(() => createQueryClient(), []);
  const antdLocale = useMemo(() => ANTD_LOCALES[locale], [locale]);
  // `buildAntdConfig` returns the theme AND the ConfigProvider props that are not tokens - `modal.mask`,
  // `drawer.mask`, `tag.styles`, all moved out of `theme.components` in antd 6. They are spread together so
  // half of them cannot be applied.
  const config = useMemo(() => buildAntdConfig(antdLocaleKeyFor(locale)), [locale]);

  return (
    <I18nextProvider i18n={i18nInstance}>
      <ConfigProvider
        locale={antdLocale}
        theme={config.theme}
        direction={config.direction}
        modal={config.modal}
        drawer={config.drawer}
        tag={config.tag}
        // `holder` is deliberately unset, so antd renders its overlays inside this subtree. That is what
        // antd's documentation requires for `message`, `notification` and the static `Modal.xxx` calls to
        // pick up this theme and direction.
      >
        <AntdApp>
          <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
        </AntdApp>
      </ConfigProvider>
    </I18nextProvider>
  );
}