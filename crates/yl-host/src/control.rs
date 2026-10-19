//! Control-plane client: signing keys, session reports and revocation.
//!
//! The Host verifies tickets locally; it does not ask the server to approve
//! every connection. A heartbeat (every second) carries session revocations so
//! an owner/admin action stops an active session within the two-second target.
//! If the control plane is unreachable for 30 seconds the Host fails closed
//! and terminates ticket-backed sessions (a bounded lease).

use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use tracing::{info, warn};

use yl_proto::auth::{
    verify_session_ticket, SessionClaims, TicketError, TicketKey, TICKET_CLOCK_SKEW_SECS,
};
use yl_proto::PERMISSION_ALL;

const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(1);
const CONTROL_LEASE: Duration = Duration::from_secs(30);
const MAX_REPLAY_ENTRIES: usize = 8192;
const MAX_RESPONSE_BYTES: u64 = 256 * 1024;

pub struct TicketStatus {
    pub valid: bool,
    pub reason: String,
}

pub struct ControlPlane {
    base_url: String,
    device_token: String,
    device_id: String,
    agent: ureq::Agent,
    keys: RwLock<Vec<TicketKey>>,
    revoked_sessions: Mutex<HashSet<String>>,
    owner_active: AtomicBool,
    last_contact: Mutex<Option<Instant>>,
    replay: Mutex<HashMap<String, i64>>,
    host_instance: String,
}

impl ControlPlane {
    /// Fetches the ticket keys and performs one heartbeat, which also verifies
    /// that this device is registered and its token is current.
    pub fn connect(base_url: &str, device_token: &str, device_id: &str) -> Result<Arc<Self>> {
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(5))
            .timeout_read(Duration::from_secs(8))
            .timeout_write(Duration::from_secs(8))
            .build();
        let keys = fetch_ticket_keys(&agent, base_url)?;
        let control = Arc::new(Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            device_token: device_token.to_string(),
            device_id: device_id.to_string(),
            agent,
            keys: RwLock::new(keys),
            revoked_sessions: Mutex::new(HashSet::new()),
            owner_active: AtomicBool::new(true),
            last_contact: Mutex::new(Some(Instant::now())),
            replay: Mutex::new(HashMap::new()),
            host_instance: new_host_instance(),
        });
        control
            .heartbeat_once()
            .context("control-plane registration check")?;
        let worker = Arc::clone(&control);
        thread::Builder::new()
            .name("yl-host-control".into())
            .spawn(move || worker.heartbeat_loop())
            .context("spawn control-plane heartbeat thread")?;
        info!(device_id = %device_id, "control plane connected");
        Ok(control)
    }

    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    pub fn owner_active(&self) -> bool {
        self.owner_active.load(Ordering::Relaxed)
    }

    pub fn session_revoked(&self, session_id: &str) -> bool {
        if session_id.is_empty() {
            return false;
        }
        if !self.owner_active() {
            return true;
        }
        self.revoked_sessions
            .lock()
            .map(|revoked| revoked.contains(session_id))
            .unwrap_or(true)
    }

    /// Verifies a ticket and, on key rotation, refreshes the announced keys
    /// once. Replay is a separate step because only the Host sees both the
    /// ticket and the connection attempt.
    pub fn verify_ticket(&self, token: &str, nonce: &str) -> Result<SessionClaims, TicketError> {
        let first = {
            let keys = self
                .keys
                .read()
                .map_err(|_| TicketError::UnknownKey)?
                .clone();
            verify_session_ticket(token, &keys, &self.device_id, nonce, unix_now())
        };
        match first {
            Err(TicketError::UnknownKey) => {
                if let Ok(keys) = fetch_ticket_keys(&self.agent, &self.base_url) {
                    if let Ok(mut stored) = self.keys.write() {
                        *stored = keys;
                    }
                    let keys = self
                        .keys
                        .read()
                        .map_err(|_| TicketError::UnknownKey)?
                        .clone();
                    return verify_session_ticket(token, &keys, &self.device_id, nonce, unix_now());
                }
                Err(TicketError::UnknownKey)
            }
            other => other,
        }
    }

    /// Records the ticket id as used. Returns false on replay or when the
    /// bounded replay cache is full.
    pub fn claim_ticket(&self, claims: &SessionClaims) -> bool {
        let now = unix_now();
        let Ok(mut replay) = self.replay.lock() else {
            return false;
        };
        replay.retain(|_, expires| *expires + TICKET_CLOCK_SKEW_SECS >= now);
        if replay.len() >= MAX_REPLAY_ENTRIES {
            warn!("ticket replay cache is full; rejecting new session");
            return false;
        }
        if replay.contains_key(&claims.jti) {
            return false;
        }
        replay.insert(claims.jti.clone(), claims.exp);
        true
    }

    pub fn check_ticket(&self, jti: &str) -> Result<TicketStatus> {
        if jti.is_empty() || jti.len() > 128 {
            bail!("invalid session ticket id");
        }
        let url = format!(
            "{}/api/v1/devices/{}/session-tickets/{}",
            self.base_url, self.device_id, jti
        );
        let response = self
            .agent
            .get(&url)
            .set("x-device-token", &self.device_token)
            .call()
            .map_err(|error| anyhow::anyhow!("check session ticket: {error}"))?;
        let value = read_json(response)?;
        Ok(TicketStatus {
            valid: value.get("valid").and_then(Value::as_bool).unwrap_or(false),
            reason: value
                .get("reason")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_string(),
        })
    }

    /// Registers the session with the control plane and records the actual
    /// permission intersection, Host instance and transport path. The caller
    /// must not expose Welcome/capture/input until this succeeds.
    pub fn report_start(
        &self,
        claims: &SessionClaims,
        permissions: u32,
        request_input: bool,
        input_allowed: bool,
    ) -> Result<()> {
        let body = json!({
            "session_id": claims.jti,
            "user_id": claims.sub,
            "permissions": permissions,
            "ticket_permissions": claims.permissions,
            "host_instance": self.host_instance,
            "request_input": request_input,
            "input_allowed": input_allowed,
            "path": if claims.mode == "quality" {"moonlight_sunshine_control_tls"} else if claims.mode == "flow" {"flow_direct_tcp_tls"} else {"direct_tcp_tls"},
        });
        let url = format!(
            "{}/api/v1/devices/{}/sessions",
            self.base_url, self.device_id
        );
        let response = self
            .agent
            .post(&url)
            .set("x-device-token", &self.device_token)
            .send_json(body)
            .map_err(|error| anyhow::anyhow!("report session start: {error}"))?;
        let value = read_json(response)?;
        if value.get("revoked").and_then(Value::as_bool) == Some(true) {
            bail!("session start was rejected because authorization was revoked");
        }
        if value.get("ok").and_then(Value::as_bool) != Some(true) {
            bail!("control plane did not confirm session start");
        }
        Ok(())
    }

    pub fn report_end(&self, session_id: &str, reason: &str) {
        if session_id.is_empty() {
            return;
        }
        let base = self.base_url.clone();
        let token = self.device_token.clone();
        let device = self.device_id.clone();
        let session = session_id.to_string();
        let reason = reason.to_string();
        spawn_report(move || {
            let agent = report_agent();
            let url = format!("{base}/api/v1/devices/{device}/sessions/{session}/end");
            if let Err(error) = agent
                .post(&url)
                .set("x-device-token", &token)
                .send_json(json!({"reason": reason}))
            {
                warn!(%error, "report session end failed");
            }
        });
    }

    fn heartbeat_loop(self: Arc<Self>) {
        loop {
            thread::sleep(HEARTBEAT_INTERVAL);
            match self.heartbeat_once() {
                Ok(()) => {
                    if let Ok(mut last) = self.last_contact.lock() {
                        *last = Some(Instant::now());
                    }
                }
                Err(error) => {
                    warn!(%error, "control-plane heartbeat failed");
                    let stale = self
                        .last_contact
                        .lock()
                        .ok()
                        .and_then(|last| *last)
                        .map(|last| last.elapsed() > CONTROL_LEASE)
                        .unwrap_or(true);
                    if stale && self.owner_active.swap(false, Ordering::Relaxed) {
                        warn!("control-plane lease expired; active sessions will be revoked");
                    }
                }
            }
        }
    }

    fn heartbeat_once(&self) -> Result<()> {
        let url = format!(
            "{}/api/v1/devices/{}/heartbeat",
            self.base_url, self.device_id
        );
        let response = self
            .agent
            .post(&url)
            .set("x-device-token", &self.device_token)
            .set("x-host-instance", &self.host_instance)
            .call()
            .map_err(|error| anyhow::anyhow!("heartbeat: {error}"))?;
        let value = read_json(response)?;
        let owner_active = value
            .get("owner_active")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        self.owner_active.store(owner_active, Ordering::Relaxed);
        if let Some(revoked) = value.get("revoked_sessions").and_then(Value::as_array) {
            if let Ok(mut set) = self.revoked_sessions.lock() {
                for session in revoked {
                    if let Some(id) = session.as_str() {
                        set.insert(id.to_string());
                    }
                }
                if set.len() > 4096 {
                    set.clear();
                }
            }
        }
        if let Ok(mut last) = self.last_contact.lock() {
            *last = Some(Instant::now());
        }
        Ok(())
    }
}

fn new_host_instance() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    format!("{}-{nanos:x}", std::process::id())
}

fn report_agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(3))
        .timeout_read(Duration::from_secs(5))
        .timeout_write(Duration::from_secs(5))
        .build()
}

fn spawn_report(f: impl FnOnce() + Send + 'static) {
    let _ = thread::Builder::new()
        .name("yl-host-report".into())
        .spawn(f);
}

fn fetch_ticket_keys(agent: &ureq::Agent, base_url: &str) -> Result<Vec<TicketKey>> {
    let url = format!(
        "{}/api/v1/server/ticket-key",
        base_url.trim_end_matches('/')
    );
    let response = agent
        .get(&url)
        .call()
        .map_err(|error| anyhow::anyhow!("fetch ticket keys: {error}"))?;
    let value = read_json(response)?;
    let keys = value
        .get("keys")
        .and_then(Value::as_array)
        .context("ticket-key response has no keys")?;
    let mut parsed = Vec::new();
    for key in keys {
        let kid = key
            .get("kid")
            .and_then(Value::as_str)
            .context("ticket key has no kid")?;
        let public_hex = key
            .get("public_key")
            .and_then(Value::as_str)
            .context("ticket key has no public_key")?;
        let public_key = hex::decode(public_hex).context("ticket key is not hex")?;
        if public_key.len() != 32 {
            bail!(
                "ticket public key has {} bytes, expected 32",
                public_key.len()
            );
        }
        if kid.len() > 64 {
            bail!("ticket key id is too long");
        }
        parsed.push(TicketKey {
            kid: kid.to_string(),
            public_key,
        });
    }
    if parsed.is_empty() {
        bail!("server announced no ticket keys");
    }
    Ok(parsed)
}

fn read_json(response: ureq::Response) -> Result<Value> {
    let mut reader = response.into_reader();
    let mut body = String::new();
    reader
        .by_ref()
        .take(MAX_RESPONSE_BYTES)
        .read_to_string(&mut body)
        .context("read control-plane response")?;
    serde_json::from_str(&body).context("parse control-plane response")
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

/// Local permissions are always the ceiling; a ticket can only narrow them.
pub fn local_permissions(allow_input: bool, file_root: bool, file_read_only: bool) -> u32 {
    let mut bits = yl_proto::PERMISSION_VIEW;
    if allow_input {
        bits |= yl_proto::PERMISSION_CONTROL;
    }
    if file_root {
        bits |= yl_proto::PERMISSION_FILE_READ;
        if !file_read_only {
            bits |= yl_proto::PERMISSION_FILE_WRITE;
        }
    }
    bits & PERMISSION_ALL
}

#[cfg(test)]
mod tests {
    use super::*;
    use yl_proto::auth::TICKET_VERSION;
    use yl_proto::auth::{generate_ticket_key, nonce_sha256, sign_ticket, TICKET_PURPOSE};

    #[test]
    fn local_permissions_are_a_ceiling() {
        assert_eq!(
            local_permissions(true, true, false),
            yl_proto::PERMISSION_VIEW
                | yl_proto::PERMISSION_CONTROL
                | yl_proto::PERMISSION_FILE_READ
                | yl_proto::PERMISSION_FILE_WRITE
        );
        assert_eq!(
            local_permissions(false, true, true),
            yl_proto::PERMISSION_VIEW | yl_proto::PERMISSION_FILE_READ
        );
    }

    fn control_with_keys(keys: Vec<TicketKey>) -> ControlPlane {
        ControlPlane {
            base_url: "http://127.0.0.1:9".into(),
            device_token: "not-used".into(),
            device_id: "yl-test".into(),
            agent: ureq::AgentBuilder::new().build(),
            keys: RwLock::new(keys),
            revoked_sessions: Mutex::new(HashSet::new()),
            owner_active: AtomicBool::new(true),
            last_contact: Mutex::new(None),
            replay: Mutex::new(HashMap::new()),
            host_instance: new_host_instance(),
        }
    }

    #[test]
    fn ticket_replay_is_rejected_and_expiry_pruned() {
        let (pkcs8, kid, public) = generate_ticket_key().unwrap();
        let nonce = "9a".repeat(32);
        let now = unix_now();
        let claims = SessionClaims {
            v: TICKET_VERSION,
            kid: kid.clone(),
            aud: "yl-test".into(),
            sub: 1,
            user: "alice".into(),
            jti: "session-1".into(),
            purpose: TICKET_PURPOSE.into(),
            mode: "tiles".into(),
            nonce_sha256: nonce_sha256(&nonce),
            permissions: yl_proto::PERMISSION_VIEW,
            iat: now,
            exp: now + 60,
        };
        let token = sign_ticket(&pkcs8, &claims).unwrap();
        let control = control_with_keys(vec![TicketKey {
            kid,
            public_key: public,
        }]);
        let verified = control.verify_ticket(&token, &nonce).unwrap();
        assert!(control.claim_ticket(&verified));
        assert!(!control.claim_ticket(&verified));
        assert!(!control.session_revoked("session-1"));
        control
            .revoked_sessions
            .lock()
            .unwrap()
            .insert("session-1".into());
        assert!(control.session_revoked("session-1"));
    }
}
