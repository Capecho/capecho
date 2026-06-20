import Link from "next/link";

import { Container } from "@/components/marketing/primitives";
import { Button } from "@/components/ui/button";
import { EchoMark } from "@/components/brand/echo-mark";

export default function NotFound() {
  return (
    <Container className="flex min-h-[60vh] max-w-xl flex-col items-center justify-center py-24 text-center">
      <EchoMark className="size-12 text-ink-3" />
      <h1 className="mt-6 font-display text-4xl font-medium tracking-[-0.02em] text-foreground">
        This page faded.
      </h1>
      <p className="mt-3 font-serif text-lg leading-relaxed text-ink-2">
        The word you were looking for isn&apos;t here — but the loop still is.
      </p>
      <div className="mt-8 flex gap-3">
        <Button asChild>
          <Link href="/">Back home</Link>
        </Button>
        <Button asChild variant="secondary">
          <Link href="/blog">Read the blog</Link>
        </Button>
      </div>
    </Container>
  );
}
