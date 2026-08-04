export function CloseButton({
  onClick,
  label = "Close the paywall",
  testId = "paywall-close",
}: {
  onClick: () => void;
  label?: string;
  testId?: string;
}) {
  return (
    <button
      aria-label={label}
      data-testid={testId}
      className="absolute right-0 top-0 flex h-7 w-7 items-center justify-center rounded-full border border-hair bg-panel text-[13px] text-sec hover:text-text focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd"
      onClick={onClick}
    >
      ✕
    </button>
  );
}
