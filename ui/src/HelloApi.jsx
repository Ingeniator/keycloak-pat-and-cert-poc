import { useState } from "react";
import styles from "./styles";

const API = "/api";

export default function HelloApi() {
  const [response, setResponse] = useState(null);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(false);

  const callHello = async () => {
    setLoading(true);
    setError(null);
    setResponse(null);

    try {
      const res = await fetch(`${API}/hello`, { credentials: "include" });
      const data = await res.json();

      if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
      setResponse(data);
    } catch (e) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={styles.card}>
      <h2 style={styles.subheading}>Backend API</h2>
      <p style={{ color: "#666", fontSize: 14, marginBottom: 12 }}>
        Call the protected <code>/hello</code> endpoint. Your session cookie
        authenticates the request — no token is sent from the browser.
      </p>

      <button style={styles.button} onClick={callHello} disabled={loading}>
        {loading ? "Calling..." : "Call /hello"}
      </button>

      {response && (
        <pre style={{ ...styles.pre, marginTop: 12 }}>
          {JSON.stringify(response, null, 2)}
        </pre>
      )}

      {error && (
        <p style={{ color: "#c0392b", fontSize: 14, marginTop: 12 }}>{error}</p>
      )}
    </div>
  );
}
