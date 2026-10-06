/**
 * `app/AppShell` - the frame around every screen.
 *
 * ## Why the sidebar is dark and the header is light
 *
 * The sidebar is chrome: it is the same on every screen and carries no information. Making it visually
 * distinct means the operator's eye lands on the content area, and it makes an accidental navigation obvious
 * at a glance. `surface.chrome` is the token that does this, chosen for contrast against every content
 * surface rather than picked as a "dark mode" colour.
 *
 * ## The 48px row, enforced once
 *
 * `Menu.itemHeight` is set to `MIN_TOUCH_TARGET` in `antd-theme.ts`, so every sidebar row is 48px because a
 * token says so. It is not set per item here, where one screen could forget it.
 */

import { Layout, Menu, Button } from "antd";
import LogoutOutlined from "@ant-design/icons/LogoutOutlined";
import type { ReactElement } from "react";
import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useLocation, useNavigate } from "react-router-dom";

import { sidebarScreens } from "./routes.js";
import { ErrorState } from "../components/StateBlock.js";
import { LocaleSwitch } from "../components/LocaleSwitch.js";
import { authError, signOut as signOutOfSupabase } from "../lib/auth.js";

const { Header, Sider, Content } = Layout;

export function AppShell({ children }: { readonly children: ReactElement }): ReactElement {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const location = useLocation();
  const screens = sidebarScreens();
  const [signOutFailure, setSignOutFailure] = useState<unknown>(null);

  /**
   * The selected key is the longest matching path, not an exact match.
   *
   * `/merchants/:id` is nested under `/merchants` in the table, so on a merchant profile both match. Taking
   * the longest match keeps the parent highlighted rather than dropping the selection entirely, which is
   * what an exact-match lookup does and why an operator loses their place on every drill-down.
   */
  const selectedKey =
    screens
      .filter((screen) => location.pathname === screen.path || location.pathname.startsWith(`${screen.path}/`))
      .sort((a, b) => b.path.length - a.path.length)[0]?.key ?? "dashboard";

  /**
   * Sign out, then leave.
   *
   * The navigation happens whether or not `signOut` succeeds, because an operator who asked to sign out must
   * end up signed out. A failure is reported rather than swallowed: silently landing on the sign-in page after
   * a failed sign-out leaves a live session that *looks* closed, which is worse than an error message.
   */
  const onSignOut = async (): Promise<void> => {
    try {
      await signOutOfSupabase();
      setSignOutFailure(null);
    } catch (error) {
      setSignOutFailure(error);
    } finally {
      void navigate("/sign-in", { replace: true });
    }
  };

  return (
    <Layout className="app-shell">
      <Sider className="app-shell__sidebar" width={240} breakpoint="lg" collapsedWidth={0}>
        <Menu
          theme="dark"
          mode="inline"
          // `selectedKeys` not `defaultSelectedKeys`: the latter is uncontrolled and would leave the
          // highlight behind after a client-side navigation.
          selectedKeys={[selectedKey]}
          onClick={({ key }) => {
            const screen = screens.find((candidate) => candidate.key === key);
            if (screen !== undefined) {
              void navigate(screen.path);
            }
          }}
          items={screens.map((screen) => ({
            key: screen.key,
            label: t(`nav.${screen.key}`),
          }))}
        />
      </Sider>
      <Header className="app-shell__header">
        <span className="metric-card__label">{t("app.console")}</span>
        <div className="page__actions">
          <LocaleSwitch />
          <Button
            icon={<LogoutOutlined />}
            onClick={() => void onSignOut()}
            className="row-action"
            // A labelled button, not an icon. An icon-only control is a guess, and a tooltip is only
            // reachable by hover, which excludes a keyboard and a touch screen.
            aria-label={t("app.signOut")}
          >
            {t("app.signOut")}
          </Button>
        </div>
      </Header>
      <Content className="app-shell__content">
        {signOutFailure === null ? null : (
          <ErrorState error={authError(signOutFailure)} onRetry={() => void onSignOut()} />
        )}
        {children}
      </Content>
    </Layout>
  );
}