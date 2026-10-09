/**
 * `className` on React Native components.
 *
 * This file must stay a module — it has the `export {}` below. `declare module "x"` in a module
 * AUGMENTS the real module; in a script file it declares an ambient module that SHADOWS the real
 * one, which breaks every import from the package it names.
 *
 * Uniwind ships this augmentation against the `react-native` root, but RN 0.86 declares these props
 * in the individual component modules, so the root-level merge applies to nothing. These target the
 * modules that actually declare them.
 */

import "react-native";
import "react-native-safe-area-context";

declare module "react-native/Libraries/Components/View/ViewPropTypes" {
  interface ViewProps {
    className?: string;
  }
}

declare module "react-native/Libraries/Text/Text" {
  interface TextProps {
    className?: string;
  }
}

declare module "react-native/Libraries/Components/ScrollView/ScrollView" {
  interface ScrollViewProps {
    className?: string;
    contentContainerClassName?: string;
  }
}

declare module "react-native-safe-area-context" {
  interface SafeAreaViewProps {
    className?: string;
  }
}

export {};