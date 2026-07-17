import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  fetchStatuslineConfig,
  fetchStatuslineMeta,
  previewStatusline,
  saveStatuslineConfig,
  type SLConfig,
  type SLOptionSpec,
  type SLPreset,
  type SLSegmentConfig,
  type SLSegmentSpec,
} from "../api.ts";
import { parseAnsi } from "./ansi.ts";
import { ShellDialog } from "./dialog.tsx";

// Settings → Statusline: drag/toggle/options/preset over ONE registry served
// by the daemon; the preview is the REAL renderer's bytes, never a JS mock.

function MiniToggle(props: { on: boolean; onChange: (on: boolean) => void; label: string }) {
  return (
    <button
      role="switch"
      aria-checked={props.on}
      aria-label={props.label}
      onClick={() => props.onChange(!props.on)}
      className={`relative h-[16px] w-[28px] shrink-0 rounded-full transition-colors duration-150 ${
        props.on ? "bg-accent" : "bg-rail"
      }`}
    >
      <i
        className={`absolute top-[2px] h-[12px] w-[12px] rounded-full bg-white shadow transition-[left] duration-150 ${
          props.on ? "left-[14px]" : "left-[2px]"
        }`}
      />
    </button>
  );
}

function OptionControl(props: {
  spec: SLOptionSpec;
  segLabel: string;
  value: unknown;
  onChange: (v: unknown) => void;
}) {
  const { spec } = props;
  const label = `${props.segLabel}: ${spec.label}`;
  if (spec.type === "bool") {
    return (
      <label className="flex items-center gap-1.5 text-[10.5px] text-sec">
        {spec.label}
        <MiniToggle
          on={(props.value ?? spec.default) === true}
          onChange={(on) => props.onChange(on)}
          label={label}
        />
      </label>
    );
  }
  if (spec.type === "enum") {
    return (
      <label className="flex items-center gap-1.5 text-[10.5px] text-sec">
        {spec.label}
        <select
          aria-label={label}
          className="rounded-md border border-hair bg-win px-1.5 py-0.5 text-[10.5px]"
          value={String(props.value ?? spec.default ?? spec.values?.[0] ?? "")}
          onChange={(e) => props.onChange(e.target.value)}
        >
          {(spec.values ?? []).map((v) => (
            <option key={v} value={v}>
              {v}
            </option>
          ))}
        </select>
      </label>
    );
  }
  if (spec.type === "color") {
    const set = typeof props.value === "string" && props.value !== "";
    return (
      <label className="flex items-center gap-1.5 text-[10.5px] text-sec">
        {spec.label}
        <input
          type="color"
          aria-label={label}
          className="h-[18px] w-[26px] cursor-pointer border-0 bg-transparent p-0"
          value={set ? (props.value as string) : "#0a7aff"}
          onChange={(e) => props.onChange(e.target.value)}
        />
        {set && (
          <button
            className="text-[10px] text-ter hover:text-sec"
            aria-label={`Clear ${label}`}
            onClick={() => props.onChange(undefined)}
          >
            clear
          </button>
        )}
      </label>
    );
  }
  return (
    <label className="flex items-center gap-1.5 text-[10.5px] text-sec">
      {spec.label}
      <input
        type="text"
        aria-label={label}
        className="w-[150px] rounded-md border border-hair bg-win px-1.5 py-0.5 text-[10.5px]"
        value={String(props.value ?? "")}
        onChange={(e) => props.onChange(e.target.value === "" ? undefined : e.target.value)}
      />
    </label>
  );
}

export function StatuslineDialog(props: {
  open: boolean;
  onOpenChange: (o: boolean) => void;
  offline?: boolean;
}) {
  const [meta, setMeta] = useState<{ segments: SLSegmentSpec[]; presets: SLPreset[] } | null>(null);
  const [saved, setSaved] = useState<SLConfig | null>(null);
  const [draft, setDraft] = useState<SLConfig | null>(null);
  const [preview, setPreview] = useState<string>("");
  const [err, setErr] = useState<string | null>(null);
  const [applied, setApplied] = useState(false);
  const dragFrom = useRef<number | null>(null);

  useEffect(() => {
    if (!props.open || props.offline) return;
    setApplied(false);
    Promise.all([fetchStatuslineMeta(), fetchStatuslineConfig()])
      .then(([m, c]) => {
        setMeta(m);
        setSaved(c.config);
        setDraft(c.config);
        setErr(c.load_error ? `statusline.json is unreadable — showing defaults. ${c.load_error}` : null);
      })
      .catch(() => setErr("Editor unreachable — daemon not running or too old."));
  }, [props.open, props.offline]);

  // Live preview: debounce drafts through the daemon's real renderer.
  useEffect(() => {
    if (!draft || props.offline) return;
    const t = setTimeout(() => {
      previewStatusline(draft, 120, "truecolor")
        .then((p) => setPreview(p.line))
        .catch((e: unknown) => setErr(e instanceof Error ? e.message : "Preview failed."));
    }, 200);
    return () => clearTimeout(t);
  }, [draft, props.offline]);

  const patch = useCallback((fn: (c: SLConfig) => SLConfig) => {
    setApplied(false);
    setDraft((d) => (d ? fn(d) : d));
  }, []);

  const specOf = useMemo(() => {
    const m = new Map<string, SLSegmentSpec>();
    meta?.segments.forEach((s) => m.set(s.id, s));
    return m;
  }, [meta]);

  const inLine = new Set((draft?.segments ?? []).map((s) => s.id));
  const available = (meta?.segments ?? []).filter((s) => !inLine.has(s.id));
  const dirty = JSON.stringify(draft) !== JSON.stringify(saved);

  const move = (from: number, to: number) =>
    patch((c) => {
      if (to < 0 || to >= c.segments.length) return c;
      const segs = [...c.segments];
      const [row] = segs.splice(from, 1);
      segs.splice(to, 0, row);
      return { ...c, segments: segs, preset: "" };
    });

  const apply = () => {
    if (!draft) return;
    saveStatuslineConfig(draft)
      .then(() => {
        setSaved(draft);
        setApplied(true);
        setErr(null);
      })
      .catch((e: unknown) =>
        setErr(e instanceof Error ? e.message : "Save failed — the daemon didn't take it."),
      );
  };

  return (
    <ShellDialog open={props.open} onOpenChange={props.onOpenChange} title="Statusline" width={600}>
      {props.offline ? (
        <p className="text-[12px] leading-relaxed text-sec">
          Statusline editing needs the daemon — the preview is rendered by it, the same code that
          prints your terminal line. Start it:{" "}
          <code className="font-semibold">llmpilot daemon run</code>
        </p>
      ) : (
        <>
          <div className="rounded-lg bg-hudbg px-3 py-2.5">
            {draft?.keep?.command && (
              <div className="mb-1 font-mono text-[11.5px] text-graydot italic">
                (your kept statusline renders here: {draft.keep.command})
              </div>
            )}
            <div
              data-testid="sl-preview"
              tabIndex={0}
              role="region"
              aria-label="Statusline preview"
              className="overflow-x-auto font-mono text-[11.5px] whitespace-pre text-hudtx tabular-nums focus:outline-none focus-visible:ring-1 focus-visible:ring-acc-bd"
            >
              {preview ? (
                parseAnsi(preview).map((s, i) => (
                  <span key={i} style={{ color: s.color, opacity: s.dim ? 0.55 : 1 }}>
                    {s.text}
                  </span>
                ))
              ) : (
                <span className="text-graydot">rendering…</span>
              )}
            </div>
          </div>
          <p className="text-[10.5px] text-ter">
            Rendered by the daemon's real renderer, shown at 120 columns, full color. Your
            terminal's own width and color depth apply there. Session fields (model, dir, cost)
            show sample values here.
          </p>

          {err && (
            <p className="rounded-lg border border-warnbd bg-warnbg px-3 py-2 text-[11px] text-warn">
              {err}
            </p>
          )}

          {draft?.keep?.command && (
            <div className="flex items-center justify-between gap-2 rounded-lg border border-hair px-2.5 py-1.5">
              <div className="text-[11px] text-sec">
                <span className="font-semibold">Kept statusline</span> — runs above the llmpilot
                line: <code className="text-[10.5px]">{draft.keep.command}</code>
              </div>
              <button
                aria-label="Remove kept statusline"
                onClick={() => patch((c) => ({ ...c, keep: undefined }))}
                className="rounded px-1 text-[11px] text-ter hover:text-crit"
              >
                ✕
              </button>
            </div>
          )}

          <div className="flex gap-2">
            {(meta?.presets ?? []).map((p) => (
              <button
                key={p.id}
                onClick={() => {
                  setApplied(false);
                  // presets swap the segment composition; a kept coexist line
                  // is orthogonal and survives the swap
                  setDraft((d) => ({ ...p.config, preset: p.id, keep: d?.keep }));
                }}
                className={`flex-1 rounded-lg border px-2.5 py-2 text-left transition-colors duration-150 ${
                  draft?.preset === p.id ? "border-acc-bd bg-acc-a" : "border-hair hover:bg-wash"
                }`}
              >
                <div className="text-[11.5px] font-semibold">{p.name}</div>
                <div className="mt-0.5 text-[10px] leading-snug text-ter">{p.desc}</div>
              </button>
            ))}
          </div>

          <div>
            <div className="mb-1 text-[10.5px] font-semibold tracking-wide text-ter uppercase">
              Your line — drag to reorder
            </div>
            <ul className="flex flex-col">
              {(draft?.segments ?? []).map((sc: SLSegmentConfig, i) => {
                const spec = specOf.get(sc.id);
                return (
                  <li
                    key={sc.id}
                    draggable
                    onDragStart={() => (dragFrom.current = i)}
                    onDragOver={(e) => e.preventDefault()}
                    onDrop={() => {
                      if (dragFrom.current !== null) move(dragFrom.current, i);
                      dragFrom.current = null;
                    }}
                    className="flex flex-wrap items-center gap-x-2.5 gap-y-1 border-b border-hairsoft py-1.5 last:border-b-0"
                  >
                    <span aria-hidden="true" className="cursor-grab text-[11px] text-graydot">
                      ≡
                    </span>
                    <span className="text-[12px] font-semibold">{spec?.name ?? sc.id}</span>
                    {spec?.fleet && (
                      <span className="rounded bg-chipbg px-1 py-px text-[9px] font-semibold text-acc-tx">
                        daemon
                      </span>
                    )}
                    <span className="flex flex-wrap items-center gap-2.5">
                      {(spec?.options ?? []).map((o) => (
                        <OptionControl
                          key={o.key}
                          spec={o}
                          segLabel={spec?.name ?? sc.id}
                          value={sc.options?.[o.key]}
                          onChange={(v) =>
                            patch((c) => ({
                              ...c,
                              preset: "",
                              segments: c.segments.map((row) => {
                                if (row.id !== sc.id) return row;
                                const options = { ...row.options };
                                if (v === undefined) delete options[o.key];
                                else options[o.key] = v;
                                return { ...row, options };
                              }),
                            }))
                          }
                        />
                      ))}
                    </span>
                    <span className="ml-auto flex items-center gap-1">
                      <button
                        aria-label={`Move ${spec?.name ?? sc.id} up`}
                        disabled={i === 0}
                        onClick={() => move(i, i - 1)}
                        className="rounded px-1 text-[11px] text-ter hover:text-sec disabled:opacity-30"
                      >
                        ↑
                      </button>
                      <button
                        aria-label={`Move ${spec?.name ?? sc.id} down`}
                        disabled={i === (draft?.segments.length ?? 0) - 1}
                        onClick={() => move(i, i + 1)}
                        className="rounded px-1 text-[11px] text-ter hover:text-sec disabled:opacity-30"
                      >
                        ↓
                      </button>
                      <button
                        aria-label={`Remove ${spec?.name ?? sc.id}`}
                        onClick={() =>
                          patch((c) => ({
                            ...c,
                            preset: "",
                            segments: c.segments.filter((row) => row.id !== sc.id),
                          }))
                        }
                        className="rounded px-1 text-[11px] text-ter hover:text-crit"
                      >
                        ✕
                      </button>
                    </span>
                  </li>
                );
              })}
              {(draft?.segments.length ?? 0) === 0 && (
                <li className="py-1.5 text-[11px] text-ter">
                  Empty line — add at least one segment below.
                </li>
              )}
            </ul>
          </div>

          {available.length > 0 && (
            <div>
              <div className="mb-1 text-[10.5px] font-semibold tracking-wide text-ter uppercase">
                Add segments
              </div>
              <div className="flex flex-wrap gap-1.5">
                {available.map((s) => (
                  <button
                    key={s.id}
                    title={s.desc}
                    aria-label={`Add ${s.name}`}
                    onClick={() =>
                      patch((c) => ({
                        ...c,
                        preset: "",
                        segments: [...c.segments, { id: s.id }],
                      }))
                    }
                    className="rounded-full border border-hair px-2 py-0.5 text-[10.5px] text-sec transition-colors duration-150 hover:bg-wash"
                  >
                    + {s.name}
                  </button>
                ))}
              </div>
            </div>
          )}

          <div className="flex items-center gap-2 border-t border-hairsoft pt-3">
            <button
              onClick={apply}
              disabled={!dirty || (draft?.segments.length ?? 0) === 0}
              className="rounded-lg bg-accent px-3 py-1.5 text-[12px] font-semibold text-white transition-colors duration-150 disabled:opacity-40"
            >
              Apply changes
            </button>
            <button
              onClick={() => {
                setDraft(saved);
                setApplied(false);
              }}
              disabled={!dirty}
              className="rounded-lg border border-hair px-3 py-1.5 text-[12px] text-sec transition-colors duration-150 hover:bg-wash disabled:opacity-40"
            >
              Discard changes
            </button>
            {applied && (
              <span role="status" className="text-[11px] text-ok-tx">
                Applied — your line updates on its next refresh.
              </span>
            )}
          </div>
          <p className="text-[10.5px] text-ter">
            Not wired into Claude Code yet? Run{" "}
            <code className="font-semibold">llmpilot statusline install</code> — an existing
            statusline is kept unless you say otherwise.
          </p>
        </>
      )}
    </ShellDialog>
  );
}
