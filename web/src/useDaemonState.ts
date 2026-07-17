import { useEffect, useState } from "react";
import { fetchState, normalizeState, type Connection, type State } from "./api.ts";

// Hydrate once from GET /v1/state, then stay live over SSE /v1/events.
// EventSource reconnects on its own; "down" renders the designed degraded
// state, never a spinner forever. `disabled` (fixtures mode) opens nothing —
// keeps screenshots/tests deterministic and network-idle.
export function useDaemonState(disabled = false): { state: State | null; conn: Connection } {
  const [state, setState] = useState<State | null>(null);
  const [conn, setConn] = useState<Connection>("connecting");

  useEffect(() => {
    if (disabled) return;
    let closed = false;

    fetchState()
      .then((st) => {
        if (!closed) setState(st);
      })
      .catch(() => {
        if (!closed) setConn("down");
      });

    const es = new EventSource("/v1/events");
    es.addEventListener("state", (ev) => {
      if (closed) return;
      setConn("live");
      setState(normalizeState(JSON.parse((ev as MessageEvent).data) as State));
    });
    es.onerror = () => {
      if (!closed) setConn("down");
    };

    return () => {
      closed = true;
      es.close();
    };
  }, [disabled]);

  return { state, conn };
}
