/**
 * A call to action. Tier-0 wrapper: applies our tokens to PanelUI's Button and nothing more. Past
 * ~15 lines it would be implementing rather than wrapping, which means the behaviour belongs in
 * the feature.
 *
 * The prop surface is deliberately narrow. Forwarding all of Button's props would make this a
 * second API to learn and callers would start passing `variant`, defeating the point.
 */

import { Button } from "panelui-native";

export interface PrimaryButtonProps {
  readonly label: string;
  readonly onPress: () => void;
  readonly loading?: boolean;
  readonly disabled?: boolean;
  readonly variant?: "primary" | "outline";
  readonly className?: string;
  readonly testID?: string;
}

export function PrimaryButton({
  label,
  onPress,
  loading = false,
  disabled = false,
  variant = "primary",
  className,
  testID,
}: PrimaryButtonProps) {
  return (
    <Button
      variant={variant}
      onPress={onPress}
      loading={loading}
      // loading already blocks presses; the explicit disable stops a double submit when the tap
      // lands between the press and the state update.
      disabled={disabled || loading}
      // exactOptionalPropertyTypes: an absent optional prop must be omitted, not set to undefined.
      {...(className === undefined ? {} : { className })}
      {...(testID === undefined ? {} : { testID })}
    >
      {label}
    </Button>
  );
}