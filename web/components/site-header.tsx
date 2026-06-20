"use client";

import * as React from "react";
import Link from "next/link";
import { Menu, X } from "lucide-react";

import { cn } from "@/lib/utils";
import { mainNav } from "@/lib/site";
import { Button } from "@/components/ui/button";
import { Wordmark } from "@/components/brand/wordmark";
import { ThemeToggle } from "@/components/theme-toggle";

export function SiteHeader() {
  const [open, setOpen] = React.useState(false);
  // Condensed state (DESIGN.md §10): once the page scrolls, the bar shrinks and
  // its ground turns more opaque + grows a hairline, so content passing beneath
  // never bleeds through onto the wordmark/links.
  const [scrolled, setScrolled] = React.useState(false);

  React.useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 4);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header
      className={cn(
        "sticky top-0 z-50 w-full backdrop-blur-md transition-[background-color,border-color] duration-200",
        scrolled
          ? "border-b border-border bg-canvas/92"
          : "border-b border-transparent bg-canvas/80"
      )}
    >
      <div
        className={cn(
          "mx-auto flex max-w-6xl items-center justify-between gap-4 px-5 transition-[height] duration-200 sm:px-8",
          scrolled ? "h-14" : "h-16"
        )}
      >
        <Wordmark />

        <nav className="hidden items-center gap-1 md:flex">
          {mainNav.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="rounded-md px-3 py-2 font-sans text-sm font-medium text-ink-2 transition-colors hover:bg-accent hover:text-foreground"
            >
              {item.title}
            </Link>
          ))}
        </nav>

        <div className="flex items-center gap-2">
          <ThemeToggle />
          <Button asChild size="sm" className="hidden sm:inline-flex">
            <Link href="/download">Get Capecho</Link>
          </Button>
          <Button
            variant="ghost"
            size="icon"
            className="md:hidden"
            aria-label="Toggle menu"
            aria-expanded={open}
            onClick={() => setOpen((v) => !v)}
          >
            {open ? <X /> : <Menu />}
          </Button>
        </div>
      </div>

      {/* Mobile menu */}
      <div
        className={cn(
          "border-t border-border bg-canvas md:hidden",
          open ? "block" : "hidden"
        )}
      >
        <nav className="mx-auto flex max-w-6xl flex-col gap-1 px-5 py-3">
          {mainNav.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              onClick={() => setOpen(false)}
              className="rounded-md px-3 py-2.5 font-sans text-sm font-medium text-ink-2 hover:bg-accent hover:text-foreground"
            >
              {item.title}
            </Link>
          ))}
          <Button asChild className="mt-2">
            <Link href="/download" onClick={() => setOpen(false)}>
              Get Capecho
            </Link>
          </Button>
        </nav>
      </div>
    </header>
  );
}
