import { useEffect, useState } from "react";
import { ApiError, fetchState, normalizeState, type Connection, type State } from "./api.ts";
import { authHeaders } from "./auth.ts";

// Hydrate once from GET /v1/state, then stay live over SSE /v1/events.
// EventSource cannot send the Authorization header every read now needs, so
// the stream is a fetch reader that reconnects itself after a short backoff;
// "down" renders the designed degraded state, never a spinner forever, and
// "auth" names a missing session token instead of a dead daemon. `disabled`
// (fixtures mode) opens nothing — keeps screenshots/tests deterministic and
// network-idle.
const RECONNECT_MS = 3000;

function isAuthRequired(err: unknown): boolean {
  return err instanceof ApiError && err.code === "auth_required";
}

export function useDaemonState(disabled = false): { state: State | null; conn: Connection } {
  const [state, setState] = useState<State | null>(null);
  const [conn, setConn] = useState<Connection>("connecting");

  useEffect(() => {
    if (disabled) return;
    const ctrl = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;

    fetchState()
      .then((st) => {
        if (!ctrl.signal.aborted) setState(st);
      })
      .catch((err) => {
        if (!ctrl.signal.aborted) setConn(isAuthRequired(err) ? "auth" : "down");
      });

    // One SSE frame: "event: state" + "data: <json>" lines, blank-line framed.
    const onFrame = (frame: string) => {
      let event = "message";
      const data: string[] = [];
      for (const line of frame.split("\n")) {
        if (line.startsWith("event:")) event = line.slice(6).trim();
        else if (line.startsWith("data:")) data.push(line.slice(5).replace(/^ /, ""));
      }
      if (event !== "state" || data.length === 0) return;
      setConn("live");
      setState(normalizeState(JSON.parse(data.join("\n")) as State));
    };

    const connect = async () => {
      try {
        const res = await fetch("/v1/events", {
          headers: { Accept: "text/event-stream", ...authHeaders() },
          signal: ctrl.signal,
        });
        if (!res.ok || !res.body) {
          if (res.status === 401) {
            const body = (await res.json().catch(() => null)) as { code?: string } | null;
            if (body?.code === "auth_required") {
              // A missing token never fixes itself on retry; stop here.
              setConn("auth");
              return;
            }
          }
          throw new Error(`events: HTTP ${res.status}`);
        }
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buf = "";
        try {
          for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            buf += decoder.decode(value, { stream: true });
            let cut: number;
            while ((cut = buf.indexOf("\n\n")) >= 0) {
              const frame = buf.slice(0, cut);
              buf = buf.slice(cut + 2);
              try {
                onFrame(frame);
              } catch {
                // One unreadable frame skips; the stream stays up.
              }
            }
          }
        } finally {
          // Release the connection before any reconnect opens a new one.
          void reader.cancel().catch(() => {});
        }
      } catch {
        // Fall through to the reconnect below; an abort is the unmount.
      }
      if (ctrl.signal.aborted) return;
      setConn("down");
      timer = setTimeout(connect, RECONNECT_MS);
    };
    void connect();

    return () => {
      ctrl.abort();
      clearTimeout(timer);
    };
  }, [disabled]);

  return { state, conn };
}
