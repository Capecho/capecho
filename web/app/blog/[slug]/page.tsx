import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { compileMDX } from "next-mdx-remote/rsc";
import remarkGfm from "remark-gfm";
import rehypeSlug from "rehype-slug";
import rehypeAutolinkHeadings from "rehype-autolink-headings";
import { ArrowLeft } from "lucide-react";

import { siteConfig } from "@/lib/site";
import { getPost, getPostSlugs, formatDate, type PostFrontmatter } from "@/lib/blog";
import { Container } from "@/components/marketing/primitives";
import { Badge } from "@/components/ui/badge";
import { CtaSection } from "@/components/marketing/cta";
import { mdxComponents } from "@/components/mdx";

export const dynamicParams = false;

export function generateStaticParams() {
  return getPostSlugs().map((slug) => ({ slug }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}): Promise<Metadata> {
  const { slug } = await params;
  const post = getPost(slug);
  if (!post) return {};
  const url = `${siteConfig.url}/blog/${post.slug}`;
  return {
    title: post.title,
    description: post.description,
    keywords: post.keywords,
    alternates: { canonical: `/blog/${post.slug}` },
    openGraph: {
      type: "article",
      url,
      title: post.title,
      description: post.description,
      publishedTime: post.date,
    },
    twitter: {
      card: "summary_large_image",
      title: post.title,
      description: post.description,
    },
  };
}

export default async function BlogPost({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const post = getPost(slug);
  if (!post) notFound();

  const { content } = await compileMDX<PostFrontmatter>({
    source: post.content,
    components: mdxComponents,
    options: {
      mdxOptions: {
        remarkPlugins: [remarkGfm],
        rehypePlugins: [
          rehypeSlug,
          [rehypeAutolinkHeadings, { behavior: "wrap" }],
        ],
      },
    },
  });

  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "BlogPosting",
    headline: post.title,
    description: post.description,
    datePublished: post.date,
    author: { "@type": "Organization", name: post.author ?? "Capecho" },
    publisher: { "@type": "Organization", name: "Capecho" },
    mainEntityOfPage: `${siteConfig.url}/blog/${post.slug}`,
  };

  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />

      <article className="pt-16 pb-4 sm:pt-24">
        <Container className="max-w-2xl">
          <Link
            href="/blog"
            className="inline-flex items-center gap-1.5 font-sans text-sm text-ink-2 transition-colors hover:text-foreground"
          >
            <ArrowLeft className="size-4" />
            All posts
          </Link>

          <div className="mt-8 flex items-center gap-3">
            <Badge variant="outline">{post.category}</Badge>
            <time className="font-mono text-xs text-ink-2">
              {formatDate(post.date)}
            </time>
          </div>

          <h1 className="mt-4 font-display text-4xl font-medium leading-[1.1] tracking-[-0.025em] text-foreground sm:text-[2.75rem]">
            {post.title}
          </h1>
          <p className="mt-4 font-serif text-xl leading-relaxed text-ink-2">
            {post.description}
          </p>

          <div className="mt-10 border-t border-border pt-2">{content}</div>
        </Container>
      </article>

      <CtaSection title="Capture the next word you don't know." />
    </>
  );
}
