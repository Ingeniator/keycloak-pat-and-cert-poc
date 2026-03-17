import styles from "./styles";

export default function TokenInfo({ user }) {
  const fields = [
    ["Subject", user.sub],
    ["Username", user.preferred_username],
    ["Email", user.email],
    ["Email verified", String(user.email_verified ?? "—")],
    ["Name", [user.given_name, user.family_name].filter(Boolean).join(" ") || "—"],
    ["Issuer", user.iss],
    ["Token expires", new Date(user.exp * 1000).toLocaleString()],
  ];

  return (
    <div style={styles.card}>
      <h2 style={styles.subheading}>Account info</h2>
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
    </div>
  );
}
