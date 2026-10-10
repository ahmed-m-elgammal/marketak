/**
 * Firebase backend for the telemetry slot (F-08).
 *
 * `@react-native-firebase/{analytics,crashlytics}@26.4.0` (modular API),
 * aligned to SDK 57 (`npm run align` gates the versions). Untested at unit
 * level — constructing the instances needs the native module, and every
 * branch worth asserting lives in `provider.ts` behind the seam.
 *
 * Expo Go boundary: the Go client carries no Firebase native modules, so a
 * static import would fail the whole boot there (observed: `NativeRNFBTurbo
 * App is not registered` cascading into a missing-default-export report).
 * The modules load behind a guarded `require` instead: Expo Go degrades to
 * a silent backend with a one-time warning, development builds get the
 * real backend. Firebase on a device always means a development build —
 * DebugView, crash reports and push delivery never work in Expo Go.
 *
 * Crashlytics identity note: the SDK sets a user id but never unsets one,
 * so sign-out clears Analytics identity only; the Crashlytics id persists
 * until the next sign-in overwrites it. Stated, not worked around.
 */
import type { AnalyticsBackend, EventParams } from "./provider.js";

type AnalyticsModule = typeof import("@react-native-firebase/analytics");
type CrashModule = typeof import("@react-native-firebase/crashlytics");

const silentBackend: AnalyticsBackend = {
  logEvent(): void {},
  breadcrumb(): void {},
  setCollectionEnabled(): void {},
  setUser(): void {},
  recordError(): void {},
};

let warned = false;

function degraded(reason: string): AnalyticsBackend {
  if (!warned) {
    warned = true;
    console.warn(
      `Firebase unavailable (${reason}); analytics and crash reporting are off. Use a development build for Firebase.`,
    );
  }
  return silentBackend;
}

function realBackend(analyticsModule: AnalyticsModule, crashModule: CrashModule): AnalyticsBackend {
  const analytics = analyticsModule.getAnalytics();
  const crashlytics = crashModule.getCrashlytics();
  return {
    logEvent(name: string, params: EventParams): void {
      analyticsModule.logEvent(analytics, name, { ...params });
    },
    breadcrumb(message: string): void {
      crashModule.log(crashlytics, message);
    },
    setCollectionEnabled(enabled: boolean): void {
      void analyticsModule.setAnalyticsCollectionEnabled(analytics, enabled);
      void crashModule.setCrashlyticsCollectionEnabled(crashlytics, enabled);
    },
    setUser(userId: string | null): void {
      void analyticsModule.setUserId(analytics, userId);
      if (userId !== null) {
        void crashModule.setUserId(crashlytics, userId);
      }
    },
    recordError(error: Error): void {
      crashModule.recordError(crashlytics, error);
    },
  };
}

function loadBackend(): AnalyticsBackend {
  let analyticsModule: AnalyticsModule;
  let crashModule: CrashModule;
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports -- the native module is absent in Expo Go; a static import fails the whole boot there. The catch degrades to silent in Go and stays loud everywhere else.
    analyticsModule = require("@react-native-firebase/analytics") as AnalyticsModule;
    // eslint-disable-next-line @typescript-eslint/no-require-imports -- see above.
    crashModule = require("@react-native-firebase/crashlytics") as CrashModule;
  } catch {
    return degraded("native module missing — Expo Go cannot carry Firebase");
  }
  return realBackend(analyticsModule, crashModule);
}

let singleton: AnalyticsBackend | null = null;

export function firebaseBackend(): AnalyticsBackend {
  if (singleton !== null) return singleton;
  singleton = loadBackend();
  return singleton;
}
