/**
 * Profile completion — the constitution 18 gate. The phone is a profile field, never a credential,
 * so there is no OTP.
 *
 * The client checks only the obvious shape so nobody waits a round trip to learn they typed a
 * letter. PHONE_INVALID and PHONE_IN_USE come from the database, which is the only place that knows
 * whether a number already belongs to a rider or another shopper.
 */

import { useState } from "react";
import { createForm, Field, Input } from "panelui-native";
import { ScrollView, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { PrimaryButton } from "@/components/ui/buttons/PrimaryButton";
// Sibling path, not the barrel: a screen importing the barrel that re-exports it is a cycle.
import { useSession } from "@/features/auth/hooks/use-session";
import { useCopy } from "@/lib/i18n";
import { capture, reportError } from "@/services/analytics";
import { isAppError } from "@/services/errors/app-error";

interface ProfileValues {
  firstName: string;
  lastName: string;
  phone: string;
}

const ProfileForm = createForm<ProfileValues>();

// Deliberately permissive: international formats vary, so anything stricter would reject valid
// numbers in some market.
function phoneProblem(digits: number, tooShort: string, tooLong: string): string | undefined {
  if (digits < 8) return tooShort;
  if (digits > 15) return tooLong;
  return undefined;
}

// exactOptionalPropertyTypes forbids passing undefined to an optional prop; the key must be absent.
function errorProps(error: string | undefined): { errorMessage?: string } {
  return error === undefined ? {} : { errorMessage: error };
}

export function CompleteProfileScreen() {
  const t = useCopy();
  const { submitProfile } = useSession();
  const [failure, setFailure] = useState<string | null>(null);

  const form = ProfileForm.useForm({
    defaultValues: { firstName: "", lastName: "", phone: "" },
    onSubmit: async (values) => {
      setFailure(null);

      try {
        await submitProfile(values);
        // The gate now passes, so the session provider sends the shopper onward.
        capture("profile_completed");
      } catch (error) {
        // Shown verbatim: the database already wrote Arabic copy for a human.
        setFailure(
          isAppError(error) && error.serverMessage.length > 0
            ? error.serverMessage
            : t("profileFailed"),
        );
        reportError("auth:complete_profile", error);
      }
    },
  });

  return (
    <SafeAreaView className="flex-1 bg-cream" edges={["top", "bottom"]}>
      <ScrollView
        contentContainerClassName="flex-1 px-6 py-8"
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
      >
        <View className="mb-8 gap-3">
          <Text className="text-h1 text-ink">{t("profileTitle")}</Text>
          <Text className="text-body text-ink-secondary">{t("profileSubtitle")}</Text>
        </View>

        <ProfileForm form={form}>
          <View className="gap-5">
            <ProfileForm.Field
              name="firstName"
              validate={(v) => (v.trim().length > 0 ? undefined : t("fieldFirstNameRequired"))}
            >
              {(field) => (
                <Input
                  label={t("profileFirstName")}
                  value={field.value}
                  onChangeText={field.onChange}
                  onBlur={field.onBlur}
                  {...errorProps(field.error)}
                  avoidKeyboard
                  autoCapitalize="words"
                  autoComplete="given-name"
                />
              )}
            </ProfileForm.Field>

            <ProfileForm.Field
              name="lastName"
              validate={(v) => (v.trim().length > 0 ? undefined : t("fieldLastNameRequired"))}
            >
              {(field) => (
                <Input
                  label={t("profileLastName")}
                  value={field.value}
                  onChangeText={field.onChange}
                  onBlur={field.onBlur}
                  {...errorProps(field.error)}
                  avoidKeyboard
                  autoCapitalize="words"
                  autoComplete="family-name"
                />
              )}
            </ProfileForm.Field>

            <ProfileForm.Field
              name="phone"
              validate={(v) => phoneProblem(v.replace(/\D/g, "").length, t("fieldPhoneTooShort"), t("fieldPhoneTooLong"))}
            >
              {(field) => (
                <Input
                  label={t("profilePhone")}
                  value={field.value}
                  onChangeText={field.onChange}
                  onBlur={field.onBlur}
                  {...errorProps(field.error)}
                  avoidKeyboard
                  keyboardType="phone-pad"
                  autoComplete="tel"
                />
              )}
            </ProfileForm.Field>
          </View>

          {/* Field rather than a bare View, so the message is announced with the form. */}
          {failure === null ? null : (
            <Field orientation="vertical">
              <Field.Content>
                <Field.Title className="text-danger">{failure}</Field.Title>
              </Field.Content>
            </Field>
          )}

          <View className="mt-8">
            <PrimaryButton
              label={t("profileSubmit")}
              loading={form.isSubmitting}
              testID="complete-profile-submit"
              onPress={() => {
                void form.handleSubmit();
              }}
            />
          </View>
        </ProfileForm>
      </ScrollView>
    </SafeAreaView>
  );
}