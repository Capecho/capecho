import {
  Fraunces,
  Source_Serif_4,
  JetBrains_Mono,
} from "next/font/google";

/**
 * Capecho web type stack (web/DESIGN.md §3).
 * - Display / hero / section headings + wordmark + in-device app UI: Fraunces
 *   (opsz). One display serif, shared with the app + the menu-bar wordmark, so
 *   the web reads as the same product as the app rather than a separate brand.
 * - Body / content: Charter (preinstalled on Apple) → Source Serif 4 web fallback.
 * - Chrome (nav, buttons, labels): system sans — no web font, set in globals.css.
 * - Data / mono: JetBrains Mono.
 */
export const fraunces = Fraunces({
  subsets: ["latin"],
  display: "swap",
  variable: "--font-fraunces",
  axes: ["opsz"],
  style: ["normal", "italic"],
});

export const sourceSerif = Source_Serif_4({
  subsets: ["latin"],
  display: "swap",
  variable: "--font-source-serif",
});

export const jetbrainsMono = JetBrains_Mono({
  subsets: ["latin"],
  display: "swap",
  variable: "--font-jetbrains",
});
