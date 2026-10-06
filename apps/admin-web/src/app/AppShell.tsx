/**
 * `app/AppShell` - the frame every screen sits in.
 *
 * ## The structural fix that makes antd's Layout work
 *
 * antd's `Layout` is a **flex** container, and `.ant-layout-has-sider { display: flex; flex-direction: row }`
 * is injected by its runtime CSS-in-JS *after* this app's stylesheet. The first version declared
 * `display: grid` with `grid-template-areas` on `.app-shell`, lost the cascade at equal specificity, and the
 * three children became row siblings: the sidebar took 240px, the header sat beside it, and every screen
 * rendered in a ~220px column. Nothing warned. TypeScript was green and `verify` was green.
 *
 * The fix is not to out-specify antd - it is to give `Layout` the structure it is designed for, so its own
 * flexbox does the layout and no rule here fights it.
 *
 * ## Where the boldness goes
 *
 * One place: the active nav item, which gets a **leading bar plus a faint wash** rather than a solid orange
 * slab. That leaves the solid accent to the primary button, which is the only element on a screen that
 * performs an action. If the selected nav row were as loud as "Save changes", an operator's eye would be pulled
 * to navigation rather than to the thing they came to do.
 *
 * ## The header carries breadcrumbs, not a label
 *
 * It used to read "Admin console" on every page - a constant that told an operator nothing about where they
 * were. The header now shows the trail, so the answer to "which screen am I on" is in the position the eye
 * already looks.
 */

import { Layout, Menu, Breadcrumb, Dropdown, Avatar } from "antd";
import type { MenuProps } from "antd";
import LogoutOutlined from "@ant-design/icons/LogoutOutlined";
import DownOutlined from "@ant-design/icons/DownOutlined";
import type { ReactElement } from "react";
import { useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { Link, Outlet, useLocation, useNavigate } from "react-router-dom";

import { ErrorState } from "../components/StateBlock.js";
import { LocaleSwitch } from "../components/LocaleSwitch.js";
import { authError, signOut as signOutOfSupabase } from "../lib/auth.js";
import { useQueryClient } from "@tanstack/react-query";
import { SESSION_QUERY_KEY, useSession } from "../lib/use-auth.js";
import { breadcrumbFor, sidebarScreens, SECTIONS } from "./routes.js";

const { Header, Sider, Content } = Layout;

export function AppShell(): ReactElement {
  const { t, i18n } = useTranslation();
  /*
   * `i18n.t` rather than the render-scoped `t`. `breadcrumbFor` is called outside JSX and needs a translator
   * function, and i18next types `t` contravariantly in its key parameter - so the render-scoped `t` is not
   * assignable to a plain `(key: string, values?) => string`. Passing `i18n.t` works because it carries the
   * same generic signature rather than a hand-written one.
   */
  const translate = i18n.t;
  const navigate = useNavigate();
  const location = useLocation();
  const queryClient = useQueryClient();
  const screens = sidebarScreens();
  const [signOutFailure, setSignOutFailure] = useState<unknown>(null);
  const session = useSession();

  /**
   * The selected key is the longest matching path, not an exact match.
   *
   * `/merchants/:id` is nested under `/merchants`, so on a merchant profile both match. Taking the longest
   * keeps the parent highlighted rather than dropping the selection entirely, which is what an exact-match
   * lookup does - and why an operator loses their place on every drill-down.
   */
  const selectedKey =
    screens
      .filter((screen) => location.pathname === screen.path || location.pathname.startsWith(`${screen.path}/`))
      .sort((a, b) => b.path.length - a.path.length)[0]?.key ?? "dashboard";

  const items: MenuProps["items"] = useMemo(
    () =>
      SECTIONS.filter((section) => screens.some((screen) => screen.section === section)).map((section) => ({
        key: section,
        type: "group" as const,
        label: t(`nav.section.${section}`),
        children: screens
          .filter((screen) => screen.section === section)
          .map((screen) => ({
            key: screen.key,
            label: t(`nav.${screen.key}`),
            // A real link, so middle-click, copy-link and "open in new tab" all work.\n            label: <Link to={screen.path}>{t(`nav.${screen.key}`)}</Link>,
          })),
      })),
    [screens, t],
  );

  /**
   * Sign out, then leave.
   *
   * The navigation happens whether or not `signOut` succeeds, because an operator who asked to sign out must
   * end up signed out. A failure is reported rather than swallowed: silently landing on the sign-in page after a
   * failed sign-out leaves a live session that *looks* closed, which is worse than an error message.
   */
  const onSignOut = async (): Promise<void> => {
    try {
      await signOutOfSupabase();
      setSignOutFailure(null);
      queryClient.setQueryData(SESSION_QUERY_KEY, null);
    } catch (error) {
      setSignOutFailure(error);
    } finally {
      void navigate("/sign-in", { replace: true });
    }
  };

  const trail = breadcrumbFor(location.pathname, translate);
  const email = session?.user.email ?? "";

  return (
    <Layout className="app-shell">
      {/*
        `sticky` rather than a fixed grid row: the sidebar scrolls independently on a long list, which is what
        an operator scrolling 200 merchants wants. `100vh` not `100%` so it reaches the viewport edge exactly.
      */}
      <Sider
        className="app-shell__sidebar"
        width={232}
        // Below 1024 the sidebar collapses to zero width and the menu moves into a drawer, because a 232px
        // column plus a table of eight columns leaves no room for the merchant names on a tablet.
        breakpoint="lg"
        collapsedWidth={0}
        trigger={null}
      >
        {/*
          The brand sits at the top of the sidebar, full-bleed to the edge - not in the header. A wordmark in
          the header would compete with the breadcrumbs for the same horizontal band, and it is the one piece of
          branding that has to be visible from every screen without scrolling.
        */}
        <Link to="/" className="brand">
          <span className="brand__mark" aria-hidden="true">
            M
          </span>
          <span className="brand__name">{t("app.console")}</span>
        </Link>

        <Menu
          theme="dark"
          mode="inline"
          // `selectedKeys` not `defaultSelectedKeys`: the latter is uncontrolled and leaves the highlight behind
          // after a client-side navigation.
          selectedKeys={[selectedKey]}
          items={items}
          className="app-shell__menu"
        />
      </Sider>

      <Layout className="app-shell__body">
        <Header className="app-shell__header">
          {/*
            Breadcrumbs, replacing the "Admin console" string that used to sit here. On the dashboard this
            renders nothing rather than a lone item - a breadcrumb trail with one crumb is a label, and the page
            already has a title.
          */}
          {trail.length > 1 ? (
            <Breadcrumb
              items={trail.map((crumb) => ({
                title: crumb.href === undefined ? crumb.label : <Link to={crumb.href}>{crumb.label}</Link>,
              }))}
              className="crumbs"
            />
          ) : null}

          <div className="app-shell__account">
            <LocaleSwitch />

            {/*
              The user menu, rather than a labelled Sign out button.
              *
              * "Sign out" is an action an operator takes perhaps once a shift, and as a full button it was the
              * heaviest control in the header - competing with the page's actual primary action for attention.
              * A menu says "who am I, and what can I do here" and keeps the action one click away.
            */}
            <Dropdown
              trigger={["click"]}
              menu={{
                items: [
                  { key: "role", label: t("app.adminRole"), disabled: true },
                  { type: "divider" },
                  {
                    key: "signout",
                    icon: <LogoutOutlined />,
                    label: t("app.signOut"),
                    onClick: () => void onSignOut(),
                  },
                ],
              }}
            >
              {/*
                A real button, not a div: `Dropdown` needs a focusable trigger, and an operator using a keyboard
                must be able to open this menu without a mouse. `ghost` because it is chrome, not an action.
              */}
              <button type="button" className="account-trigger" aria-label={t("app.accountMenu")}>
                <Avatar size={28} className="account-trigger__avatar">
                  {email.charAt(0).toUpperCase()}
                </Avatar>
                <span className="account-trigger__name">{email}</span>
                <DownOutlined className="account-trigger__caret" />
              </button>
            </Dropdown>
          </div>
        </Header>

        <Content className="app-shell__content">
          {signOutFailure === null ? null : (
            <ErrorState error={authError(signOutFailure)} onRetry={() => void onSignOut()} />
          )}
          <Outlet />
        </Content>
      </Layout>
    </Layout>
  );
}