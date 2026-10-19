//! Short-lived session tickets signed by the control-plane server.
//!
//! A ticket is `yl1.<base64url(payload)>.<base64url(ed25519 signature)>`.
//! The signature covers `yl1.<payload>`, so neither the prefix nor the claims
//! can be changed without invalidating it. The Host verifies offline: it only
//! needs the server's public keys, which it fetches at startup.
//!
//! Tickets are bound to:
//! - the target device id (`aud`),
//! - the requesting account (`sub`/`user`),
//! - one connection nonce (`nonce_sha256`),
//! - one purpose (`remote_session`),
//! - a permission bitmask,
//! - an issue/expiry window and a unique `jti` (the Host keeps a replay cache).

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use ring::rand::SystemRandom;
use ring::signature::{Ed25519KeyPair, KeyPair, UnparsedPublicKey, ED25519};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::PERMISSION_ALL;

pub const TICKET_PREFIX: &str = "yl1";
pub const TICKET_PURPOSE: &str = "remote_session";
pub const TICKET_VERSION: u8 = 2;
pub const TICKET_CLOCK_SKEW_SECS: i64 = 90;
pub const TICKET_MAX_BYTES: usize = 8192;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionClaims {
    pub v: u8,
    pub kid: String,
    pub aud: String,
    pub sub: i64,
    pub user: String,
    pub jti: String,
    pub purpose: String,
    pub mode: String,
    pub nonce_sha256: String,
    pub permissions: u32,
    pub iat: i64,
    pub exp: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TicketKey {
    pub kid: String,
    /// Raw 32-byte Ed25519 public key.
    pub public_key: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TicketError {
    Malformed,
    UnknownKey,
    BadSignature,
    WrongVersion,
    WrongPurpose,
    WrongAudience,
    NonceMismatch,
    NotYetValid,
    Expired,
    InvalidPermissions,
}

impl std::fmt::Display for TicketError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let text = match self {
            Self::Malformed => "ticket is malformed",
            Self::UnknownKey => "ticket signing key is unknown",
            Self::BadSignature => "ticket signature is invalid",
            Self::WrongVersion => "ticket version is unsupported",
            Self::WrongPurpose => "ticket purpose is not remote_session",
            Self::WrongAudience => "ticket was issued for another device",
            Self::NonceMismatch => "ticket is bound to a different connection nonce",
            Self::NotYetValid => "ticket is not valid yet",
            Self::Expired => "ticket has expired",
            Self::InvalidPermissions => "ticket permissions are invalid",
        };
        f.write_str(text)
    }
}

impl std::error::Error for TicketError {}

/// Generates a new Ed25519 key pair. Returns `(pkcs8_private, kid, public)`.
pub fn generate_ticket_key() -> Result<(Vec<u8>, String, Vec<u8>), TicketError> {
    let rng = SystemRandom::new();
    let pkcs8 = Ed25519KeyPair::generate_pkcs8(&rng).map_err(|_| TicketError::Malformed)?;
    let key_pair =
        Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).map_err(|_| TicketError::Malformed)?;
    let public_key = key_pair.public_key().as_ref().to_vec();
    let kid = kid_for_public(&public_key);
    Ok((pkcs8.as_ref().to_vec(), kid, public_key))
}

pub fn kid_for_public(public_key: &[u8]) -> String {
    let digest = Sha256::digest(public_key);
    hex::encode(&digest[..8])
}

pub fn ticket_key_from_pkcs8(pkcs8: &[u8]) -> Result<TicketKey, TicketError> {
    let key_pair = Ed25519KeyPair::from_pkcs8(pkcs8).map_err(|_| TicketError::Malformed)?;
    let public_key = key_pair.public_key().as_ref().to_vec();
    Ok(TicketKey {
        kid: kid_for_public(&public_key),
        public_key,
    })
}

pub fn nonce_sha256(nonce: &str) -> String {
    hex::encode(Sha256::digest(nonce.as_bytes()))
}

/// Signs the claims. `claims.kid` must belong to `pkcs8`.
pub fn sign_ticket(pkcs8: &[u8], claims: &SessionClaims) -> Result<String, TicketError> {
    let key_pair = Ed25519KeyPair::from_pkcs8(pkcs8).map_err(|_| TicketError::Malformed)?;
    let expected_kid = kid_for_public(key_pair.public_key().as_ref());
    if claims.kid != expected_kid {
        return Err(TicketError::UnknownKey);
    }
    let payload = serde_json::to_vec(claims).map_err(|_| TicketError::Malformed)?;
    let payload_b64 = URL_SAFE_NO_PAD.encode(payload);
    let signing_input = format!("{TICKET_PREFIX}.{payload_b64}");
    let signature = key_pair.sign(signing_input.as_bytes());
    Ok(format!(
        "{signing_input}.{}",
        URL_SAFE_NO_PAD.encode(signature.as_ref())
    ))
}

/// Verifies signature, time window, audience, purpose, nonce binding and
/// permission bits. Replay (`jti`) is enforced by the Host, which is the only
/// component that sees both the ticket and the connection.
pub fn verify_session_ticket(
    token: &str,
    keys: &[TicketKey],
    expected_aud: &str,
    expected_nonce: &str,
    now: i64,
) -> Result<SessionClaims, TicketError> {
    if token.len() > TICKET_MAX_BYTES {
        return Err(TicketError::Malformed);
    }
    let mut parts = token.split('.');
    let prefix = parts.next().ok_or(TicketError::Malformed)?;
    let payload_b64 = parts.next().ok_or(TicketError::Malformed)?;
    let signature_b64 = parts.next().ok_or(TicketError::Malformed)?;
    if parts.next().is_some() || prefix != TICKET_PREFIX {
        return Err(TicketError::Malformed);
    }
    let payload = URL_SAFE_NO_PAD
        .decode(payload_b64)
        .map_err(|_| TicketError::Malformed)?;
    let signature = URL_SAFE_NO_PAD
        .decode(signature_b64)
        .map_err(|_| TicketError::Malformed)?;
    let claims: SessionClaims =
        serde_json::from_slice(&payload).map_err(|_| TicketError::Malformed)?;
    let key = keys
        .iter()
        .find(|key| key.kid == claims.kid)
        .ok_or(TicketError::UnknownKey)?;
    let signing_input = format!("{TICKET_PREFIX}.{payload_b64}");
    UnparsedPublicKey::new(&ED25519, &key.public_key)
        .verify(signing_input.as_bytes(), &signature)
        .map_err(|_| TicketError::BadSignature)?;

    if claims.v != TICKET_VERSION {
        return Err(TicketError::WrongVersion);
    }
    if claims.purpose != TICKET_PURPOSE {
        return Err(TicketError::WrongPurpose);
    }
    if claims.aud != expected_aud {
        return Err(TicketError::WrongAudience);
    }
    if claims.nonce_sha256 != nonce_sha256(expected_nonce) {
        return Err(TicketError::NonceMismatch);
    }
    if !matches!(claims.mode.as_str(), "tiles" | "flow" | "quality") {
        return Err(TicketError::WrongPurpose);
    }
    if claims.permissions == 0 || claims.permissions & !PERMISSION_ALL != 0 {
        return Err(TicketError::InvalidPermissions);
    }
    if claims.iat - TICKET_CLOCK_SKEW_SECS > now {
        return Err(TicketError::NotYetValid);
    }
    if claims.exp + TICKET_CLOCK_SKEW_SECS < now {
        return Err(TicketError::Expired);
    }
    if claims.exp <= claims.iat {
        return Err(TicketError::Malformed);
    }
    if claims.jti.is_empty() || claims.jti.len() > 128 {
        return Err(TicketError::Malformed);
    }
    Ok(claims)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{PERMISSION_CONTROL, PERMISSION_VIEW};

    fn claims(kid: &str, aud: &str, nonce: &str, now: i64) -> SessionClaims {
        SessionClaims {
            v: TICKET_VERSION,
            kid: kid.to_string(),
            aud: aud.to_string(),
            sub: 7,
            user: "alice".into(),
            jti: "jti-1".into(),
            purpose: TICKET_PURPOSE.into(),
            mode: "tiles".into(),
            nonce_sha256: nonce_sha256(nonce),
            permissions: PERMISSION_VIEW | PERMISSION_CONTROL,
            iat: now,
            exp: now + 600,
        }
    }

    #[test]
    fn signs_and_verifies_the_full_binding() {
        let (pkcs8, kid, public) = generate_ticket_key().unwrap();
        let nonce = "ab".repeat(32);
        let token = sign_ticket(&pkcs8, &claims(&kid, "yl-host", &nonce, 1000)).unwrap();
        let keys = [TicketKey {
            kid: kid.clone(),
            public_key: public,
        }];
        let parsed = verify_session_ticket(&token, &keys, "yl-host", &nonce, 1200).unwrap();
        assert_eq!(parsed.user, "alice");
        assert_eq!(parsed.jti, "jti-1");
        assert_eq!(parsed.permissions, PERMISSION_VIEW | PERMISSION_CONTROL);
    }

    #[test]
    fn rejects_tampering_and_wrong_bindings() {
        let (pkcs8, kid, public) = generate_ticket_key().unwrap();
        let nonce = "cd".repeat(32);
        let token = sign_ticket(&pkcs8, &claims(&kid, "yl-host", &nonce, 1000)).unwrap();
        let keys = [TicketKey {
            kid,
            public_key: public,
        }];
        assert_eq!(
            verify_session_ticket(&token, &keys, "yl-other", &nonce, 1000),
            Err(TicketError::WrongAudience)
        );
        assert_eq!(
            verify_session_ticket(&token, &keys, "yl-host", &"ef".repeat(32), 1000),
            Err(TicketError::NonceMismatch)
        );
        let mut tampered = token.clone();
        tampered.push('A');
        assert!(verify_session_ticket(&tampered, &keys, "yl-host", &nonce, 1000).is_err());
        assert_eq!(
            verify_session_ticket(&token, &keys, "yl-host", &nonce, 2000),
            Err(TicketError::Expired)
        );
        assert_eq!(
            verify_session_ticket(&token, &keys, "yl-host", &nonce, 800),
            Err(TicketError::NotYetValid)
        );
    }

    #[test]
    fn rejects_unknown_key_and_invalid_permissions() {
        let (pkcs8, kid, public) = generate_ticket_key().unwrap();
        let nonce = "12".repeat(32);
        let mut ticket = claims(&kid, "yl-host", &nonce, 1000);
        ticket.permissions = 1 << 20;
        let token = sign_ticket(&pkcs8, &ticket).unwrap();
        let (_, other_kid, other_public) = generate_ticket_key().unwrap();
        let wrong_keys = [TicketKey {
            kid: other_kid,
            public_key: other_public,
        }];
        assert_eq!(
            verify_session_ticket(&token, &wrong_keys, "yl-host", &nonce, 1000),
            Err(TicketError::UnknownKey)
        );
        let keys = [TicketKey {
            kid,
            public_key: public,
        }];
        assert_eq!(
            verify_session_ticket(&token, &keys, "yl-host", &nonce, 1000),
            Err(TicketError::InvalidPermissions)
        );
    }
}
