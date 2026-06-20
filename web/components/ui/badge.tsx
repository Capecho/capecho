import * as React from "react";
import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";

import { cn } from "@/lib/utils";

/**
 * Badge — meta-pill (DESIGN.md §Typography meta-pill: 11px, uppercase, tracked).
 * Default uses the latte chip; outline is a quiet eyebrow.
 */
const badgeVariants = cva(
  "inline-flex items-center gap-1.5 rounded-full border font-sans text-[11px] font-semibold uppercase tracking-[0.04em] leading-none",
  {
    variants: {
      variant: {
        default: "border-transparent bg-chip text-chip-foreground px-2.5 py-1",
        outline: "border-border text-muted-foreground px-2.5 py-1",
        primary:
          "border-transparent bg-primary text-primary-foreground px-2.5 py-1",
        soft: "border-transparent bg-[var(--app-primary-soft)] text-foreground px-2.5 py-1",
      },
    },
    defaultVariants: {
      variant: "default",
    },
  }
);

function Badge({
  className,
  variant,
  asChild = false,
  ...props
}: React.ComponentProps<"span"> &
  VariantProps<typeof badgeVariants> & { asChild?: boolean }) {
  const Comp = asChild ? Slot : "span";
  return (
    <Comp
      data-slot="badge"
      className={cn(badgeVariants({ variant, className }))}
      {...props}
    />
  );
}

export { Badge, badgeVariants };
