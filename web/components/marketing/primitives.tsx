import { cn } from "@/lib/utils";
import { Badge } from "@/components/ui/badge";

export function Container({
  className,
  children,
}: {
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <div className={cn("mx-auto w-full max-w-6xl px-3 sm:px-8", className)}>
      {children}
    </div>
  );
}

export function Eyebrow({ children }: { children: React.ReactNode }) {
  return (
    <Badge variant="soft" className="mb-4">
      {children}
    </Badge>
  );
}
