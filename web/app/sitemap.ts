import type { MetadataRoute } from "next";

import { siteConfig } from "@/lib/site";
import { landingSlugs } from "@/lib/landing-pages";
import { getAllPosts } from "@/lib/blog";

export default function sitemap(): MetadataRoute.Sitemap {
  const base = siteConfig.url;
  const now = new Date();

  const staticRoutes = [
    "",
    "/how-it-works",
    "/privacy",
    "/download",
    "/faq",
    "/pricing",
    "/blog",
    "/about",
    "/contact",
    "/legal/privacy-policy",
    "/legal/cookies",
    "/legal/terms",
  ];

  const staticEntries: MetadataRoute.Sitemap = staticRoutes.map((route) => ({
    url: `${base}${route}`,
    lastModified: now,
    changeFrequency: route === "" ? "weekly" : "monthly",
    priority: route === "" ? 1 : 0.7,
  }));

  const landingEntries: MetadataRoute.Sitemap = landingSlugs().map((slug) => ({
    url: `${base}/${slug}`,
    lastModified: now,
    changeFrequency: "monthly",
    priority: 0.8,
  }));

  const postEntries: MetadataRoute.Sitemap = getAllPosts().map((post) => ({
    url: `${base}/blog/${post.slug}`,
    lastModified: new Date(`${post.date}T00:00:00Z`),
    changeFrequency: "yearly",
    priority: 0.6,
  }));

  return [...staticEntries, ...landingEntries, ...postEntries];
}
