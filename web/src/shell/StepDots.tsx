// First-run step dots: position only, no labels — the screens name
// themselves. Rendered by every screen of the onboarding flow; never by the
// standalone paywall overlay (reopening later is not a guided run).
export function StepDots({ step, total }: { step: number; total: number }) {
  return (
    <div
      className="mb-6 flex justify-center gap-1.5"
      role="img"
      aria-label={`Step ${step + 1} of ${total}`}
    >
      {Array.from({ length: total }, (_, i) => (
        <i
          key={i}
          className={`h-[5px] w-[5px] rounded-full transition-colors duration-200 ${
            i === step ? "bg-accent" : i < step ? "bg-acc-b" : "bg-rail"
          }`}
        />
      ))}
    </div>
  );
}
