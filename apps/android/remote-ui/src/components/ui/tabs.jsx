import { cn } from '../../lib/utils.js';

export function Tabs({ className, ...props }) {
  return <div className={cn('w-full', className)} {...props} />;
}

export function TabsList({ className, ...props }) {
  return <div className={cn('inline-flex h-10 items-center justify-center rounded-md bg-muted p-1 text-muted-foreground', className)} {...props} />;
}

export function TabsTrigger({ active, className, ...props }) {
  return (
    <button
      className={cn(
        'inline-flex cursor-pointer items-center justify-center whitespace-nowrap rounded-sm px-3 py-1.5 text-sm font-medium transition-all hover:bg-background hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring',
        active && 'bg-background text-foreground shadow-sm',
        className,
      )}
      {...props}
    />
  );
}
