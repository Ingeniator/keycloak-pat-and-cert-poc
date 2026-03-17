import { useState, useEffect } from "react";
import styles from "./styles";

const API = "/api";
const ATTR_FINGERPRINT = "x509_certificate_fingerprint";

/**
 * Compute SHA-256 fingerprint of a DER-encoded certificate,
 * matching the Java authenticator: colon-separated uppercase hex.
 */
async function computeCertFingerprint(pemString) {
  const b64 = pemString
    .replace(/-----BEGIN CERTIFICATE-----/, "")
    .replace(/-----END CERTIFICATE-----/, "")
    .replace(/\s/g, "");
  const der = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));

  const digest = await crypto.subtle.digest("SHA-256", der);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).toUpperCase().padStart(2, "0"))
    .join(":");
}

export default function PublicKeyForm({ user }) {
  const [fingerprints, setFingerprints] = useState([]);
  const [certPem, setCertPem] = useState("");
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);

  const loadAccount = async () => {
    const res = await fetch(`${API}/account`, { credentials: "include" });
    if (!res.ok) throw new Error(`Failed to load account (${res.status})`);
    return res.json();
  };

  useEffect(() => {
    loadAccount()
      .then((data) => {
        const fps = data.attributes?.[ATTR_FINGERPRINT] ?? [];
        setFingerprints(Array.isArray(fps) ? fps : [fps]);
      })
      .catch((e) => setError(e.message))
      .finally(() => setLoading(false));
  }, []);

  const handleAddCert = async () => {
    setSaved(false);
    setError(null);

    try {
      const fp = await computeCertFingerprint(certPem);

      if (fingerprints.includes(fp)) {
        setError("This certificate is already registered");
        return;
      }

      const account = await loadAccount();
      const updated = [...fingerprints, fp];

      const res = await fetch(`${API}/account`, {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          ...account,
          attributes: {
            ...account.attributes,
            [ATTR_FINGERPRINT]: updated,
          },
        }),
      });

      if (!res.ok) {
        const body = await res.text();
        throw new Error(`Save failed (${res.status}): ${body}`);
      }

      setFingerprints(updated);
      setCertPem("");
      setSaved(true);
      setTimeout(() => setSaved(false), 3000);
    } catch (e) {
      setError(e.message);
    }
  };

  const handleRemove = async (fp) => {
    setError(null);
    try {
      const account = await loadAccount();
      const updated = fingerprints.filter((f) => f !== fp);

      const res = await fetch(`${API}/account`, {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          ...account,
          attributes: {
            ...account.attributes,
            [ATTR_FINGERPRINT]: updated,
          },
        }),
      });

      if (!res.ok) throw new Error(`Delete failed (${res.status})`);
      setFingerprints(updated);
    } catch (e) {
      setError(e.message);
    }
  };

  if (loading) return <div style={styles.card}><p>Loading certificates...</p></div>;

  return (
    <div style={styles.card}>
      <h2 style={styles.subheading}>Certificates</h2>
      <p style={{ color: "#666", fontSize: 14, marginBottom: 16 }}>
        Register your X.509 certificate to enable certificate-based login.
        Paste the PEM-encoded certificate (not the private key).
      </p>

      {fingerprints.length > 0 && (
        <div style={{ marginBottom: 16 }}>
          <h3 style={{ fontSize: 14, fontWeight: 600, marginBottom: 8 }}>
            Registered fingerprints
          </h3>
          {fingerprints.map((fp) => (
            <div key={fp} style={{
              display: "flex", alignItems: "center", justifyContent: "space-between",
              padding: "8px 12px", background: "#f5f5f5", borderRadius: 6, marginBottom: 6,
              fontFamily: "monospace", fontSize: 12, wordBreak: "break-all",
            }}>
              <span>{fp}</span>
              <button
                onClick={() => handleRemove(fp)}
                style={{ ...styles.buttonOutline, marginLeft: 12, padding: "4px 10px", fontSize: 12, color: "#c0392b", borderColor: "#c0392b" }}
              >
                Remove
              </button>
            </div>
          ))}
        </div>
      )}

      <textarea
        style={styles.textarea}
        rows={6}
        placeholder={"-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----"}
        value={certPem}
        onChange={(e) => {
          setCertPem(e.target.value);
          setSaved(false);
          setError(null);
        }}
      />

      <div style={{ display: "flex", alignItems: "center", gap: 12, marginTop: 12 }}>
        <button
          style={styles.button}
          onClick={handleAddCert}
          disabled={!certPem.includes("BEGIN CERTIFICATE")}
        >
          Register certificate
        </button>
        {saved && <span style={{ color: "#27ae60", fontSize: 14 }}>Certificate registered</span>}
        {error && <span style={{ color: "#c0392b", fontSize: 14 }}>{error}</span>}
      </div>
    </div>
  );
}
