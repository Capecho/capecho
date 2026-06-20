import * as React from "react";
import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";

import { cn } from "@/lib/utils";

/**
 * Button — Caffeine actor. The primary/secondary/chip variants carry the
 * brand's stacked-paper edge (`--shadow-edge`: a solid 3px offset, no blur) —
 * the same hard ledge the Flutter apps' primary button renders
 * (`BoxShadow(color: edge, offset: Offset(3,3))`). It grows to a 5px ledge on
 * :hover (`shadow-edge-lift`) and the button drops into a 1px press on :active
 * (`shadow-edge-press`), mirroring the app's offset 3→1 + nudge.
 */
const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md font-sans text-sm font-medium transition-all outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:size-4 [&_svg]:shrink-0 cursor-pointer",
  {
    variants: {
      variant: {
        default:
          "bg-primary text-primary-foreground shadow-edge hover:shadow-edge-lift hover:brightness-[1.02] active:translate-x-px active:translate-y-px active:shadow-edge-press",
        secondary:
          "border border-border bg-card text-foreground shadow-edge hover:bg-secondary hover:shadow-edge-lift active:translate-x-px active:translate-y-px active:shadow-edge-press",
        outline:
          "border border-border bg-transparent text-foreground hover:bg-accent",
        ghost: "text-foreground hover:bg-accent",
        link: "text-primary underline-offset-4 hover:underline",
        chip: "border border-border bg-chip text-chip-foreground shadow-edge active:translate-x-px active:translate-y-px active:shadow-edge-press",
      },
      size: {
        default: "h-10 px-5 py-2 has-[>svg]:px-4",
        sm: "h-9 rounded-md px-3.5 text-[13px]",
        lg: "h-12 rounded-lg px-7 text-base",
        icon: "size-10",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  }
);

function Button({
  className,
  variant,
  size,
  asChild = false,
  ...props
}: React.ComponentProps<"button"> &
  VariantProps<typeof buttonVariants> & {
    asChild?: boolean;
  }) {
  const Comp = asChild ? Slot : "button";
  return (
    <Comp
      data-slot="button"
      className={cn(buttonVariants({ variant, size, className }))}
      {...props}
    />
  );
}

export { Button, buttonVariants };
