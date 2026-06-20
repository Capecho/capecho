import fs from "node:fs";
import path from "node:path";
import matter from "gray-matter";

const BLOG_DIR = path.join(process.cwd(), "content", "blog");

/** Blog categories (SEO report §14). */
export const blogCategories = [
  "Words in Context",
  "AI Vocabulary Explanation",
  "OCR Capture",
  "SRS Review",
  "Anki Workflow",
  "Privacy",
  "Language Learning",
] as const;

export type BlogCategory = (typeof blogCategories)[number];

export type PostFrontmatter = {
  title: string;
  description: string;
  date: string; // ISO yyyy-mm-dd
  category: BlogCategory;
  author?: string;
  keywords?: string[];
  draft?: boolean;
};

export type PostMeta = PostFrontmatter & {
  slug: string;
};

export type Post = PostMeta & {
  content: string;
};

function readPostFile(fileName: string): Post {
  const slug = fileName.replace(/\.mdx?$/, "");
  const raw = fs.readFileSync(path.join(BLOG_DIR, fileName), "utf8");
  const { data, content } = matter(raw);
  return { slug, content, ...(data as PostFrontmatter) };
}

export function getAllPosts(): PostMeta[] {
  if (!fs.existsSync(BLOG_DIR)) return [];
  // Post is a superset of PostMeta (adds `content`); returning it as PostMeta[]
  // is structurally fine — callers that list posts simply ignore the body.
  return fs
    .readdirSync(BLOG_DIR)
    .filter((f) => /\.mdx?$/.test(f))
    .map(readPostFile)
    .filter((p) => p.draft !== true)
    .sort((a, b) => (a.date < b.date ? 1 : -1));
}

export function getPost(slug: string): Post | undefined {
  for (const ext of [".mdx", ".md"]) {
    const file = path.join(BLOG_DIR, `${slug}${ext}`);
    if (fs.existsSync(file)) return readPostFile(`${slug}${ext}`);
  }
  return undefined;
}

export function getPostSlugs(): string[] {
  return getAllPosts().map((p) => p.slug);
}

export function formatDate(iso: string): string {
  return new Date(`${iso}T00:00:00Z`).toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });
}
