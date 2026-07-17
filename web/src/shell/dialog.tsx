import { Dialog } from "radix-ui";
import type { ReactNode } from "react";

// Shared native-instrument dialog chrome: boxes are for interruptions only
// (pack §material rules) — one card, hairline ring, window shadow.
export function ShellDialog(props: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  children: ReactNode;
  width?: number;
}) {
  return (
    <Dialog.Root open={props.open} onOpenChange={props.onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 bg-black/25" />
        <Dialog.Content
          style={{ width: props.width ?? 440 }}
          className="fixed top-1/2 left-1/2 max-h-[88vh] max-w-[92vw] -translate-x-1/2 -translate-y-1/2
            overflow-y-auto rounded-[11px] border border-hair bg-win p-5 shadow-window focus:outline-none"
        >
          <Dialog.Title className="text-[15px] font-bold tracking-[-0.01em]">
            {props.title}
          </Dialog.Title>
          <div className="mt-3 flex flex-col gap-3">{props.children}</div>
          <Dialog.Close asChild>
            <button
              aria-label="Close"
              className="absolute top-4 right-4 rounded px-1.5 text-[13px] text-ter hover:text-sec"
            >
              ✕
            </button>
          </Dialog.Close>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
