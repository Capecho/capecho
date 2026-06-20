import type { Metadata } from "next";
import Link from "next/link";

import { getAllPosts, formatDate } from "@/lib/blog";
import { Container, Eyebrow } from "@/components/marketing/primitives";
import { Badge } from "@/components/ui/badge";

export const metadata: Metadata = {
  title: "Blog — Context, AI, and remembering what you read",
  description:
    "Notes on learning vocabulary in context, AI word explanation, OCR capture, spaced repetition, and reading more without forgetting.",
  alternates: { canonical: "/blog" },
};

export default function BlogIndex() {
  const posts = getAllPosts();

  return (
    <section className="pt-16 pb-8 sm:pt-24">
      <Container className="max-w-4xl">
        <Eyebrow>Blog</Eyebrow>
        <h1 className="font-display text-4xl font-medium leading-[1.08] tracking-[-0.025em] text-foreground sm:text-5xl">
          Context, AI, and remembering what you read
        </h1>
        <p className="mt-5 max-w-2xl font-serif text-xl leading-relaxed text-ink-2">
          Field notes on learning vocabulary in context, explaining words with
          AI, capturing from any screen, and making spaced repetition actually
          stick.
        </p>

        <div className="mt-14 divide-y divide-border border-t border-border">
          {posts.length === 0 && (
            <p className="py-10 font-serif text-lg text-ink-2">
              The first posts are on their way.
            </p>
          )}
          {posts.map((post) => (
            <article key={post.slug} className="group py-8">
              <Link href={`/blog/${post.slug}`} className="block">
                <div className="flex items-center gap-3">
                  <Badge variant="outline">{post.category}</Badge>
                  <time className="font-mono text-xs text-ink-2">
                    {formatDate(post.date)}
                  </time>
                </div>
                <h2 className="mt-3 font-display text-2xl font-medium tracking-[-0.01em] text-foreground transition-colors group-hover:text-primary">
                  {post.title}
                </h2>
                <p className="mt-2 max-w-2xl font-serif text-lg leading-relaxed text-ink-2">
                  {post.description}
                </p>
              </Link>
            </article>
          ))}
        </div>
      </Container>
    </section>
  );
}
