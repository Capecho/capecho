import type { Metadata } from "next";
import Script from "next/script";

import "./globals.css";
import {
  fraunces,
  sourceSerif,
  jetbrainsMono,
} from "@/app/fonts";
import { siteConfig } from "@/lib/site";
import { ThemeProvider } from "@/components/theme-provider";
import { ScrollReveal } from "@/components/scroll-reveal";
import { SiteHeader } from "@/components/site-header";
import { SiteFooter } from "@/components/site-footer";
import { ConsentBanner } from "@/components/consent-banner";

export const metadata: Metadata = {
  metadataBase: new URL(siteConfig.url),
  title: {
    default: siteConfig.title,
    template: "%s · Capecho",
  },
  description: siteConfig.description,
  applicationName: "Capecho",
  keywords: [
    "capture vocabulary in context",
    "vocabulary capture app",
    "OCR vocabulary app",
    "AI vocabulary explanation",
    "SRS vocabulary app",
    "Mac vocabulary app",
    "Anki alternative for vocabulary",
    "privacy-first vocabulary capture",
  ],
  openGraph: {
    type: "website",
    siteName: "Capecho",
    url: siteConfig.url,
    title: siteConfig.title,
    description: siteConfig.description,
  },
  twitter: {
    card: "summary_large_image",
    title: siteConfig.title,
    description: siteConfig.description,
  },
  alternates: { canonical: "/" },
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html
      lang="en"
      suppressHydrationWarning
      className={`${fraunces.variable} ${sourceSerif.variable} ${jetbrainsMono.variable} h-full antialiased`}
    >
      <body className="flex min-h-full flex-col">
        {/* Gate scroll-reveal before paint so content is never hidden without JS. */}
        <script
          dangerouslySetInnerHTML={{
            __html:
              "document.documentElement.classList.add('js-reveal');setTimeout(function(){document.querySelectorAll('.reveal').forEach(function(e){e.classList.add('in')})},2600)",
          }}
        />
        {/* Google Analytics 4 (gtag.js) with Consent Mode v2 — PRODUCTION ONLY.
            analytics_storage defaults to GRANTED worldwide (auto-report) EXCEPT
            the EEA/UK/CH set (siteConfig.consentRequiredRegions), where it
            defaults to DENIED until the consent banner grants it. */}
        {siteConfig.analyticsId && process.env.NODE_ENV === "production" ? (
          <>
            <Script id="ga-consent-default" strategy="beforeInteractive">
              {`window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments);}
gtag('consent','default',{analytics_storage:'denied',ad_storage:'denied',ad_user_data:'denied',ad_personalization:'denied',wait_for_update:500,region:${JSON.stringify(
                siteConfig.consentRequiredRegions
              )}});
gtag('consent','default',{analytics_storage:'granted',ad_storage:'denied',ad_user_data:'denied',ad_personalization:'denied'});
try{var c=localStorage.getItem('capecho-consent');if(c==='granted'){gtag('consent','update',{analytics_storage:'granted'});}else if(c==='denied'){gtag('consent','update',{analytics_storage:'denied'});}}catch(e){}`}
            </Script>
            <Script
              src={`https://www.googletagmanager.com/gtag/js?id=${siteConfig.analyticsId}`}
              strategy="afterInteractive"
            />
            <Script id="ga4-init" strategy="afterInteractive">
              {`gtag('js', new Date());
gtag('config', '${siteConfig.analyticsId}', {allow_google_signals:false, allow_ad_personalization_signals:false});`}
            </Script>
          </>
        ) : null}
        <ThemeProvider
          attribute="class"
          defaultTheme="dark"
          enableSystem
          disableTransitionOnChange
        >
          <ScrollReveal />
          <SiteHeader />
          <main className="flex-1">{children}</main>
          <SiteFooter />
          {siteConfig.analyticsId && process.env.NODE_ENV === "production" ? (
            <ConsentBanner />
          ) : null}
        </ThemeProvider>
      </body>
    </html>
  );
}
