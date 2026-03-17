import React from "react";
import ReactDOM from "react-dom/client";
import { AuthProvider } from "react-oidc-context";
import App from "./App";

const oidcConfig = {
  authority: "https://localhost/realms/public",
  client_id: "ui",
  redirect_uri: window.location.origin + "/ui/",
  post_logout_redirect_uri: window.location.origin + "/ui/",
  scope: "openid profile email",
  automaticSilentRenew: true,
};

ReactDOM.createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <AuthProvider {...oidcConfig}>
      <App />
    </AuthProvider>
  </React.StrictMode>
);
