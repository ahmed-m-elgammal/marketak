/**
 * `icon` is a React node, not an ImageSource: the Google G is drawn with react-native-svg, since
 * Expo has no SVG transform and a logo is not worth a Metro plugin.
 */

import { Button } from "panelui-native";
import type { ReactNode } from "react";

export type ProviderBrand = "google" | "apple";

export interface ProviderButtonProps {
  readonly brand: ProviderBrand;
  readonly label: string;
  readonly onPress: () => void;
  readonly loading?: boolean;
  readonly disabled?: boolean;
  readonly icon?: ReactNode;
  readonly testID?: string;
}

/** Both variants are outline: brand rules forbid restyling the background. */
export function ProviderButton({
  brand,
  label,
  onPress,
  loading = false,
  disabled = false,
  icon = null,
  testID,
}: ProviderButtonProps) {
  return (
    <Button
      // Both variants are outline: brand rules forbid restyling the background, and a filled button
      // would compete with the primary CTA.
      variant="outline"
      onPress={onPress}
      loading={loading}
      disabled={disabled || loading}
      className="w-full"
      {...(testID === undefined ? {} : { testID: testID ?? `sign-in-${brand}` })}
    >
      {icon}
      {label}
    </Button>
  );
}