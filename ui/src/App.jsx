import { useAuth } from "react-oidc-context";
import TokenInfo from "./TokenInfo";
import PublicKeyForm from "./PublicKeyForm";
import HelloApi from "./HelloApi";
import styles from "./styles";

export default function App() {
  const auth = useAuth();

  if (auth.isLoading) {
    return <div style={styles.container}><p>Loading...</p></div>;
  }

  if (auth.error) {
    return (
      <div style={styles.container}>
        <div style={styles.card}>
          <h2 style={{ color: "#c0392b" }}>Authentication Error</h2>
          <pre style={styles.pre}>{auth.error.message}</pre>
          <button style={styles.button} onClick={() => auth.signinRedirect()}>
            Retry
          </button>
        </div>
      </div>
    );
  }

  if (!auth.isAuthenticated) {
    return (
      <div style={styles.container}>
        <div style={{ ...styles.card, textAlign: "center" }}>
          <h1 style={styles.heading}>Keycloak Account</h1>
          <p style={{ color: "#666", marginBottom: 24 }}>
            Sign in to manage your account and public keys.
          </p>
          <button style={styles.button} onClick={() => auth.signinRedirect()}>
            Sign in
          </button>
        </div>
      </div>
    );
  }

  return (
    <div style={styles.container}>
      <div style={styles.header}>
        <h1 style={styles.heading}>Account</h1>
        <button style={styles.buttonOutline} onClick={() => auth.signoutRedirect()}>
          Sign out
        </button>
      </div>
      <TokenInfo user={auth.user} />
      <HelloApi token={auth.user.access_token} />
      <PublicKeyForm token={auth.user.access_token} />
    </div>
  );
}
