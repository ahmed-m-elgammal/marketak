/**
 * The two providers as one block.
 *
 * Apple is conditionally rendered: signInWithApple cannot open a browser sheet on Android, and a
 * button that can only fail is worse than no button.
 */

import { Platform, View } from "react-native";
import { AppleMark } from "@/components/ui/media/AppleMark";
import { GoogleMark } from "@/components/ui/media/GoogleMark";
import { ProviderButton, type ProviderBrand } from "@/components/ui/buttons/ProviderButton";
import { useCopy } from "@/lib/i18n";

export interface ProviderButtonsProps {
  readonly pending: ProviderBrand | null;
  /** Returns void, not a promise: PanelUI's onPress expects a void handler, and an async one
   *  produces an unhandled rejection if the caller forgets to catch. */
  readonly onProvider: (brand: ProviderBrand) => void;
}

export function ProviderButtons({ pending, onProvider }: ProviderButtonsProps) {
  const t = useCopy();
  const disabled = pending !== null;

  return (
    <View className="gap-3">
      <ProviderButton
        brand="google"
        label={t("signInGoogle")}
        icon={<GoogleMark size={20} />}
        loading={pending === "google"}
        disabled={disabled}
        onPress={() => {
          onProvider("google");
        }}
      />

      {Platform.OS === "ios" ? (
        <ProviderButton
          brand="apple"
          label={t("signInApple")}
          icon={<AppleMark size={20} />}
          loading={pending === "apple"}
          disabled={disabled}
          onPress={() => {
            onProvider("apple");
          }}
        />
      ) : null}
    </View>
  );
}