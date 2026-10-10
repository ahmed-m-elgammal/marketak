/**
 * Side-effect CSS imports (`import "../theme/global.css"`) need a module
 * declaration: `nativewind/types` covers the `className` prop, not CSS
 * modules. Lives here rather than the NativeWind-managed root env file,
 * which must stay exactly as the tool writes it.
 */
declare module "*.css";

/** Bundled font files resolve to Metro asset ids (numbers), never URLs. */
declare module "*.ttf" {
  const value: number;
  export default value;
}
