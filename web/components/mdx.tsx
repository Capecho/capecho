import Link from "next/link";
import type { MDXComponents } from "mdx/types";

/** Editorial prose styling for blog MDX — serif body, Fraunces headings. */
export const mdxComponents: MDXComponents = {
  h2: (props) => (
    <h2
      className="mt-12 scroll-mt-24 font-display text-2xl font-medium tracking-[-0.02em] text-foreground"
      {...props}
    />
  ),
  h3: (props) => (
    <h3
      className="mt-8 scroll-mt-24 font-display text-xl font-medium text-foreground"
      {...props}
    />
  ),
  p: (props) => (
    <p
      className="mt-5 font-serif text-lg leading-[1.75] text-ink-2"
      {...props}
    />
  ),
  ul: (props) => (
    <ul
      className="mt-5 list-disc space-y-2 pl-6 font-serif text-lg leading-relaxed text-ink-2 marker:text-primary"
      {...props}
    />
  ),
  ol: (props) => (
    <ol
      className="mt-5 list-decimal space-y-2 pl-6 font-serif text-lg leading-relaxed text-ink-2 marker:text-ink-2"
      {...props}
    />
  ),
  li: (props) => <li className="pl-1.5" {...props} />,
  blockquote: (props) => (
    <blockquote
      className="mt-6 border-l-2 border-primary pl-5 font-serif text-xl italic leading-relaxed text-foreground"
      {...props}
    />
  ),
  a: ({ href = "#", ...props }) => (
    <Link
      href={href}
      className="font-medium text-primary underline decoration-from-font underline-offset-2 hover:no-underline"
      {...props}
    />
  ),
  hr: () => <hr className="my-10 border-border" />,
  code: (props) => (
    <code
      className="rounded bg-secondary px-1.5 py-0.5 font-mono text-[0.85em] text-foreground"
      {...props}
    />
  ),
  strong: (props) => (
    <strong className="font-semibold text-foreground" {...props} />
  ),
};
