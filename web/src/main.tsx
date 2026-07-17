import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./theme.css";
import { initAuth } from "./auth.ts";
import App from "./App.tsx";

// Move the launcher's install token out of the URL before anything renders.
initAuth();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
