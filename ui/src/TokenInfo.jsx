import styles from "./styles";

export default function TokenInfo({ user }) {
  const profile = user.profile;

  const fields = [
    ["Subject", user.profile.sub],
    ["Username", profile.preferred_username],
    ["Email", profile.email],
    ["Email verified", String(profile.email_verified ?? "—")],
    ["Name", [profile.given_name, profile.family_name].filter(Boolean).join(" ") || "—"],
    ["Issuer", user.profile.iss],
    ["Token expires", new Date(user.expires_at * 1000).toLocaleString()],
  ];

  return (
    <div style={styles.card}>
      <h2 style={styles.subheading}>Token claims</h2>
      <table style={styles.table}>
        <tbody>
          {fields.map(([label, value]) => (
            <tr key={label}>
              <td style={styles.tdLabel}>{label}</td>
              <td style={styles.tdValue}>{value}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <details style={{ marginTop: 16 }}>
        <summary style={{ cursor: "pointer", color: "#666", fontSize: 14 }}>
          Raw ID token claims
        </summary>
        <pre style={styles.pre}>{JSON.stringify(profile, null, 2)}</pre>
      </details>
    </div>
  );
}
