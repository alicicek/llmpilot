// Synthesized detent/removal/book/wall sounds — no external asset (licensing
// + offline safety), fails silent if AudioContext is unavailable or blocked.
// Adapted 1:1 from design/llmpilot-scheduler-radix.html's sfx() contract.
let ctx: AudioContext | null = null;

function sfx(freq = 2200, dur = 0.018, gain = 0.08, type: OscillatorType = "square"): void {
  try {
    ctx ??= new (window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext)();
    if (ctx.state === "suspended") void ctx.resume();
    const t = ctx.currentTime;
    const o = ctx.createOscillator();
    const g = ctx.createGain();
    const f = ctx.createBiquadFilter();
    o.type = type;
    o.frequency.value = freq;
    f.type = "bandpass";
    f.frequency.value = freq;
    f.Q.value = 1.2;
    g.gain.setValueAtTime(gain, t);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    o.connect(f);
    f.connect(g);
    g.connect(ctx.destination);
    o.start(t);
    o.stop(t + dur + 0.01);
  } catch {
    // audio unavailable — stay silent
  }
}

export const tickDetent = (): void => sfx(2400, 0.016, 0.07);
export const tickBook = (): void => {
  sfx(1400, 0.03, 0.1);
  setTimeout(() => sfx(2000, 0.025, 0.08), 45);
};
export const tickRemove = (): void => sfx(420, 0.06, 0.12, "triangle");
export const tickWall = (): void => sfx(240, 0.05, 0.1, "triangle");
