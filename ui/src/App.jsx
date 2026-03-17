import { useState, useEffect } from "react";
import TokenInfo from "./TokenInfo";
import HelloApi from "./HelloApi";
import PatManager from "./PatManager";
import PublicKeyForm from "./PublicKeyForm";
import styles from "./styles";

export default function App() {
  const [user, setUser] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch("/auth/me", { credentials: "include" })
      .then((r) => (r.ok ? r.json() : null))
      .then(setUser)
      .catch(() => setUser(null))
      .finally(() => setLoading(false));
  }, []);

  if (loading) {
    return <div style={styles.container}><p>Loading...</p></div>;
  }

  if (!user) {
    return (
      <div style={styles.container}>
        <div style={{ ...styles.card, textAlign: "center" }}>
          <h1 style={styles.heading}>Keycloak Account</h1>
          <p style={{ color: "#666", marginBottom: 24 }}>
            Sign in to manage your account and certificates.
          </p>
          <a href="/auth/login" style={{ ...styles.button, textDecoration: "none", display: "inline-block" }}>
            Sign in
          </a>
        </div>
      </div>
    );
  }

  return (
    <div style={styles.container}>
      <div style={styles.header}>
        <h1 style={styles.heading}>Account</h1>
        <a href="/auth/logout" style={{ ...styles.buttonOutline, textDecoration: "none" }}>
          Sign out
        </a>
      </div>
      <TokenInfo user={user} />
      <HelloApi />
      <PatManager user={user} />
      <PublicKeyForm user={user} />
    </div>
  );
}
