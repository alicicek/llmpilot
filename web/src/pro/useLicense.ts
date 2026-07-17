import { useCallback, useEffect, useState } from "react";
import { fetchLicense, type License } from "../api.ts";
import { fixtureLicense, proFixtureParam } from "./fixtures.ts";

// Computed once: proFixtureParam is a module constant, so the fixture identity
// stays stable across renders (no refetch loop).
const FIXTURE = fixtureLicense(proFixtureParam);

// useLicense hydrates GET /v1/license and refetches whenever the caller's
// refetch key changes — App derives it from the SSE license_status AND
// license_error projections, so both a silent activation and a terminal
// refusal (seat limit, trial email used) re-hydrate the view. In ?pro=
// fixture mode it returns a static fixture and makes no request. setLicense
// lets the paywall reflect a silent activation the instant it lands.
export function useLicense(licenseKey: string | undefined): {
  license: License | null;
  setLicense: (l: License) => void;
  reload: () => void;
} {
  const [license, setLicense] = useState<License | null>(FIXTURE);

  const reload = useCallback(() => {
    if (FIXTURE) return; // fixtures mode: deterministic, network-idle
    fetchLicense()
      .then(setLicense)
      .catch(() => setLicense(null));
  }, []);

  useEffect(() => {
    reload();
  }, [reload, licenseKey]);

  return { license, setLicense, reload };
}
