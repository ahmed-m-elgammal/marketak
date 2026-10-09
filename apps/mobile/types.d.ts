// Module declarations for bundled assets and non-typed dependencies.
//
// Expo's generated env file types the Expo SDK surface; asset types and a couple of packages still
// need declaring here. Kept to one file so there is exactly one place to look.

/// <reference types="uniwind/types" />

// `className` on React Native core components comes from Uniwind's augmentation, not from RN's own
// types. Referenced above rather than imported so the module augmentation is global - without it
// `<View className="...">` is a type error, because ViewProps has no className.
//
// There is no `*.css` module declaration, so the side-effect import in `app/_layout.tsx`
// (`import "../global.css"`) also needs naming: Tailwind v4's entry file is a build-time artifact
// that Metro resolves and TypeScript does not.
declare module "*.css";

declare module "*.png" {
  const value: number;
  export default value;
}

declare module "*.jpg" {
  const value: number;
  export default value;
}

declare module "*.svg" {
  const content: string;
  export default content;
}
