/**
 * Push-permission prompt (DESIGN §14: one-line why, manual path always).
 *
 * Rendered by screens at the moment permission matters — never at boot.
 * Copy comes from the string tables; targets and surfaces from tokens.
 * The allow/later actions belong to the caller (request vs dismiss), and
 * the settings path belongs to the denied-blocked state, not this view.
 */
import type { ReactElement } from "react";
import { Pressable, Text, View } from "react-native";
import { useT } from "../../../i18n/index";
import { colors, fonts, spacing, touch, typography } from "../../../theme/tokens";
import { deviceLanguage } from "./appInfo";

export interface NotificationPromptProps {
  readonly onAllow: () => void;
  readonly onLater: () => void;
}

export function NotificationPrompt({ onAllow, onLater }: NotificationPromptProps): ReactElement {
  const { t } = useT(deviceLanguage());
  const allowLabel = t("device.push.allow");
  const laterLabel = t("device.push.later");
  return (
    <View
      style={{
        backgroundColor: colors["surface-raster-1"],
        borderColor: colors["wire-border-mid"],
        borderWidth: 1,
        padding: spacing.md,
        gap: spacing.sm,
      }}
    >
      <Text
        style={{
          color: colors["text-primary"],
          fontFamily: fonts.display,
          fontSize: typography.titleMd.fontSize,
          fontWeight: typography.titleMd.fontWeight,
        }}
      >
        {t("device.push.title")}
      </Text>
      <Text
        style={{
          color: colors["text-muted"],
          fontFamily: fonts.body,
          fontSize: typography.bodyMd.fontSize,
        }}
      >
        {t("device.push.why")}
      </Text>
      <View style={{ flexDirection: "row", gap: spacing.sm }}>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={allowLabel}
          onPress={onAllow}
          style={{
            backgroundColor: colors["cobalt-electric"],
            minHeight: touch.targetSecondary,
            paddingStart: spacing.md,
            paddingEnd: spacing.md,
            justifyContent: "center",
          }}
        >
          <Text
            style={{
              color: colors.white,
              fontFamily: fonts.display,
              fontSize: typography.titleMd.fontSize,
              fontWeight: typography.titleMd.fontWeight,
            }}
          >
            {allowLabel}
          </Text>
        </Pressable>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={laterLabel}
          onPress={onLater}
          style={{
            minHeight: touch.targetSecondary,
            paddingStart: spacing.md,
            paddingEnd: spacing.md,
            justifyContent: "center",
          }}
        >
          <Text style={{ color: colors["text-muted"], fontFamily: fonts.body }}>
            {laterLabel}
          </Text>
        </Pressable>
      </View>
    </View>
  );
}
