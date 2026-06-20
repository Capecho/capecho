import Link from "next/link";

import { cn } from "@/lib/utils";
import { EchoMark } from "@/components/brand/echo-mark";

/**
 * Wordmark — `Capecho.` in Fraunces 600, tight tracking, with the PERIOD in the
 * primary colour (the editorial statement gesture). The echo mark sits beside
 * it in the masthead, in the primary colour (DESIGN.md §Brand Identity).
 */
export function Wordmark({
  className,
  withMark = true,
  href = "/",
}: {
  className?: string;
  withMark?: boolean;
  href?: string | null;
}) {
  const content = (
    <span className={cn("inline-flex items-center gap-2", className)}>
      {withMark && <EchoMark className="size-8 text-primary" />}
      <span className="font-logo text-[22px] font-semibold leading-[1.2] text-foreground">
        Capecho
      </span>
    </span>
  );

  if (href === null) return content;

  return (
    <Link href={href} aria-label="Capecho — home" className="inline-flex">
      {content}
    </Link>
  );
}
