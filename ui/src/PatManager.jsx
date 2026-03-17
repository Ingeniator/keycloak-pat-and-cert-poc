import { useState, useEffect } from "react";
import styles from "./styles";

const PAT_API = "/api/pat";

export default function PatManager({ user }) {
  const [tokens, setTokens] = useState([]);
  const [name, setName] = useState("");
  const [expiresInDays, setExpiresInDays] = useState(90);
  const [createdToken, setCreatedToken] = useState(null);
  const [copied, setCopied] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const loadTokens = async () => {
    try {
      const res = await fetch(`${PAT_API}/tokens`, { credentials: "include" });
      if (!res.ok) throw new Error(`Failed to load tokens (${res.status})`);
      const data = await res.json();
      setTokens(data.tokens || []);
    } catch (e) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    loadTokens();
  }, []);

  const handleCreate = async () => {
    setError(null);
    setCreatedToken(null);
    setCopied(false);

    if (!name.trim()) {
      setError("Token name is required");
      return;
    }

    try {
      const res = await fetch(`${PAT_API}/tokens`, {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: name.trim(),
          expiresInDays: expiresInDays > 0 ? expiresInDays : null,
        }),
      });

      if (!res.ok) {
        const data = await res.json();
        throw new Error(data.error || `Failed (${res.status})`);
      }

      const data = await res.json();
      setCreatedToken(data.token);
      setName("");
      loadTokens();
    } catch (e) {
      setError(e.message);
    }
  };

  const handleRevoke = async (id) => {
    setError(null);
    try {
      const res = await fetch(`${PAT_API}/tokens/${id}`, {
        method: "DELETE",
        credentials: "include",
      });
      if (!res.ok) throw new Error(`Delete failed (${res.status})`);
      setTokens(tokens.filter((t) => t.id !== id));
    } catch (e) {
      setError(e.message);
    }
  };

  const handleCopy = () => {
    navigator.clipboard.writeText(createdToken);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  if (loading) return <div style={styles.card}><p>Loading tokens...</p></div>;

  return (
    <div style={styles.card}>
      <h2 style={styles.subheading}>Personal Access Tokens</h2>
      <p style={{ color: "#666", fontSize: 14, marginBottom: 16 }}>
        Generate tokens for API access from scripts and CLI tools.
        Use as <code style={{ background: "#f5f5f5", padding: "2px 6px", borderRadius: 3 }}>
        Authorization: Bearer pat_...</code>
      </p>

      {createdToken && (
        <div style={{
          background: "#f0fdf4", border: "1px solid #86efac", borderRadius: 6,
          padding: 16, marginBottom: 16,
        }}>
          <p style={{ margin: "0 0 8px", fontWeight: 600, fontSize: 14, color: "#166534" }}>
            Token created — copy it now, it won't be shown again
          </p>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <code style={{
              flex: 1, background: "#fff", padding: "8px 12px", borderRadius: 4,
              fontFamily: "monospace", fontSize: 13, wordBreak: "break-all",
              border: "1px solid #d1d5db",
            }}>
              {createdToken}
            </code>
            <button onClick={handleCopy} style={{ ...styles.button, whiteSpace: "nowrap" }}>
              {copied ? "Copied" : "Copy"}
            </button>
          </div>
        </div>
      )}

      {error && (
        <div style={{
          background: "#fef2f2", border: "1px solid #fca5a5", borderRadius: 6,
          padding: "10px 16px", marginBottom: 16, color: "#991b1b", fontSize: 14,
        }}>
          {error}
        </div>
      )}

      <div style={{ display: "flex", gap: 8, marginBottom: 16, flexWrap: "wrap" }}>
        <input
          type="text"
          placeholder="Token name (e.g. CI Pipeline)"
          value={name}
          onChange={(e) => setName(e.target.value)}
          style={{
            flex: 1, minWidth: 200, padding: "8px 12px", border: "1px solid #d0d0d0",
            borderRadius: 6, fontSize: 14,
          }}
        />
        <select
          value={expiresInDays}
          onChange={(e) => setExpiresInDays(Number(e.target.value))}
          style={{
            padding: "8px 12px", border: "1px solid #d0d0d0",
            borderRadius: 6, fontSize: 14, background: "#fff",
          }}
        >
          <option value={30}>30 days</option>
          <option value={60}>60 days</option>
          <option value={90}>90 days</option>
          <option value={180}>180 days</option>
          <option value={365}>1 year</option>
          <option value={0}>No expiration</option>
        </select>
        <button onClick={handleCreate} style={styles.button} disabled={!name.trim()}>
          Generate token
        </button>
      </div>

      {tokens.length > 0 && (
        <div>
          <h3 style={{ fontSize: 14, fontWeight: 600, marginBottom: 8 }}>Active tokens</h3>
          {tokens.map((t) => (
            <div key={t.id} style={{
              display: "flex", alignItems: "flex-start", justifyContent: "space-between",
              padding: "12px", background: "#f9fafb", borderRadius: 6, marginBottom: 6,
              border: "1px solid #f0f0f0",
            }}>
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 600, fontSize: 14, marginBottom: 4 }}>{t.name}</div>
                <div style={{ fontSize: 12, color: "#666", lineHeight: 1.6 }}>
                  <span>Created: {formatDate(t.created_at)}</span>
                  {" · "}
                  <span>Expires: {t.expires_at === "never" ? "never" : formatDate(t.expires_at)}</span>
                  {" · "}
                  <span>Last used: {t.last_used_at === "never" ? "never" : formatDate(t.last_used_at)}</span>
                </div>
              </div>
              <button
                onClick={() => handleRevoke(t.id)}
                style={{
                  ...styles.buttonOutline, marginLeft: 12, padding: "4px 10px",
                  fontSize: 12, color: "#c0392b", borderColor: "#c0392b",
                }}
              >
                Revoke
              </button>
            </div>
          ))}
        </div>
      )}

      {tokens.length === 0 && (
        <p style={{ color: "#999", fontSize: 14, fontStyle: "italic" }}>
          No tokens yet. Generate one to get started.
        </p>
      )}
    </div>
  );
}

function formatDate(iso) {
  if (!iso) return "—";
  try {
    return new Date(iso).toLocaleDateString(undefined, {
      year: "numeric", month: "short", day: "numeric",
    });
  } catch {
    return iso;
  }
}
