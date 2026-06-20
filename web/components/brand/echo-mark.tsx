import { cn } from "@/lib/utils";

/**
 * The echo mark — three concentric ripples ")))" (DESIGN.md §Brand Identity).
 * Identity + function. Single weight, currentColor so it tints per surface.
 *
 * Disambiguation rule (DESIGN.md): STATIC = memory/identity; MOTION = "working".
 * `animate` is reserved for loading/sync states only — never decoration.
 */
export function EchoMark({
  className,
  animate = false,
  ...props
}: React.SVGProps<SVGSVGElement> & { animate?: boolean }) {
  return (
    <svg
      viewBox="0 0 28 28"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.6}
      strokeLinecap="round"
      aria-hidden="true"
      className={cn("size-[1.1em]", animate && "animate-pulse", className)}
      {...props}
    >
      <g transform="translate(-3.08 -3.5) scale(1.25)">
        <path d="M10.5 13 a 2.3 2.3 0 0 1 0 -4" transform="translate(-2.2 3)" />
        <path d="M15.5 14.7 a 5 4.1 0 0 1 0 -7.4" transform="translate(-1.7 3)" />
        <path d="M21 15.7 a 6.5 5.0 0 0 1 0 -9.4" transform="translate(-0.8 3)" />
      </g>
    </svg>
  );
}
