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

import { QueryClient, QueryClientProvider, useQueryClient } from "@tanstack/react-query";
import { App as AntdApp, ConfigProvider } from "antd";
import arEG from "antd/locale/ar_EG";
import enUS from "antd/locale/en_US";
import { useEffect, useMemo, type ReactNode } from "react";
import { I18nextProvider } from "react-i18next";

import { buildAntdConfig, cssVariablesBlock } from "@marketak/ui";

import i18nInstance, { antdLocaleKeyFor, type Locale } from "../i18n/index.js";
import { onSessionChange } from "../lib/auth.js";
import { SESSION_QUERY_KEY } from "../lib/use-auth.js";

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

/**
 * The single `onAuthStateChange` listener for the whole app.
 *
 * It lives here rather than inside `useSession` because every caller of that hook would otherwise open its
 * own subscription, and two readers could disagree about whether there is a session — which shows up as a
 * screen that renders while the guard still believes you are signed out.
 *
 * It also clears the cache on sign-out. Without that, the next operator to sign in on the same tablet sees
 * the previous operator's cached merchants and orders for up to `staleTime`. On a shared device that is a
 * data leak, not a stale read, and it is the kind of bug nobody reports because they assume the app is broken.
 *
 * **This component is rendered INSIDE `QueryClientProvider`, and it has to stay there.**
 *
 * An earlier version called this as a hook from `Providers` itself, which threw
 * `No QueryClient set, use QueryClientProvider to set one` on the first paint. The reason is ordering, and it
 * is not subtle once stated: `Providers` *renders* `QueryClientProvider`, so anything `Providers` calls runs
 * before that provider exists in the tree. A hook can only read context from an ancestor, and this one would
 * have to be its own descendant.
 *
 * The crash was in the first render of the whole app, which is the worst possible place for a provider
 * ordering mistake to hide — and it only showed up at runtime. TypeScript cannot see it: both versions are
 * well-typed.
 */
function AuthBridge(): null {
  const queryClient = useQueryClient();

  useEffect(() => {
    let unsubscribe: (() => void) | undefined;
    try {
      unsubscribe = onSessionChange((session) => {
        queryClient.setQueryData(SESSION_QUERY_KEY, session);
        if (session === null) {
          queryClient.clear();
        }
      });
    } catch {
      // A missing environment throws here. The session query surfaces the same misconfiguration to the
      // operator with an actionable message; swallowing it twice would just delay that.
    }
    return () => {
      unsubscribe?.();
    };
  }, [queryClient]);

  return null;
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
          <QueryClientProvider client={queryClient}>
            {/* Inside the provider on purpose - see AuthBridge. */}
            <AuthBridge />
            {children}
          </QueryClientProvider>
        </AntdApp>
      </ConfigProvider>
    </I18nextProvider>
  );
}