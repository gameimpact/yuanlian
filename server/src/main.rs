//! YuanLian control-plane server (development release).
//!
//! Scope: accounts, invites, sessions, device directory, pairing codes/grants
//! and a small admin UI. It is not a relay and does not carry desktop data.
//! Bind loopback by default; terminate TLS at a reverse proxy when exposing it.

use std::collections::HashMap;
use std::env;
use std::net::SocketAddr;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use argon2::password_hash::rand_core::OsRng;
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;
use axum::extract::{ConnectInfo, Path as AxumPath, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use rand::distributions::Alphanumeric;
use rand::{thread_rng, Rng};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tracing::{error, info};

use yl_proto::auth::{
    generate_ticket_key, nonce_sha256, sign_ticket, ticket_key_from_pkcs8, SessionClaims,
    TICKET_PURPOSE, TICKET_VERSION,
};
use yl_proto::{
    PERMISSION_ALL, PERMISSION_CONTROL, PERMISSION_FILE_DELETE, PERMISSION_FILE_READ,
    PERMISSION_FILE_WRITE, PERMISSION_VIEW,
};

const SESSION_TTL_SECS: i64 = 86_400;
const PAIRING_TTL_SECS: i64 = 600;
const GRANT_TTL_SECS: i64 = 7 * 86_400;
const SESSION_TICKET_TTL_SECS: i64 = 3_600;
const ADMIN_HTML: &str = include_str!("../admin/index.html");

#[derive(Clone)]
struct TicketKeyMaterial {
    kid: String,
    private_pkcs8: Vec<u8>,
}

#[derive(Clone)]
struct AppState {
    db: Arc<Mutex<Connection>>,
    started_at: i64,
    login_guard: Arc<Mutex<HashMap<String, (u32, i64)>>>,
    ticket_key: Arc<TicketKeyMaterial>,
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
}

impl ApiError {
    fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
        }
    }
    fn bad(message: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, "invalid_request", message)
    }
    fn unauthorized(message: impl Into<String>) -> Self {
        Self::new(StatusCode::UNAUTHORIZED, "unauthorized", message)
    }
    fn forbidden(message: impl Into<String>) -> Self {
        Self::new(StatusCode::FORBIDDEN, "forbidden", message)
    }
    fn not_found(message: impl Into<String>) -> Self {
        Self::new(StatusCode::NOT_FOUND, "not_found", message)
    }
    fn conflict(message: impl Into<String>) -> Self {
        Self::new(StatusCode::CONFLICT, "conflict", message)
    }
    fn internal(error: impl std::fmt::Display) -> Self {
        error!(%error, "internal server error");
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal",
            "internal server error",
        )
    }
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for ApiError {}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(json!({"error": {"code": self.code, "message": self.message}})),
        )
            .into_response()
    }
}

#[derive(Debug, Clone)]
struct AuthUser {
    id: i64,
    username: String,
    role: String,
}

#[derive(Debug, Deserialize)]
struct SetupRequest {
    username: String,
    password: String,
    server_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
}

#[derive(Debug, Deserialize)]
struct PasswordRequest {
    current_password: String,
    new_password: String,
}

#[derive(Debug, Deserialize)]
struct RegisterRequest {
    invite_code: String,
    username: String,
    password: String,
}

#[derive(Debug, Deserialize)]
struct InviteRequest {
    role: Option<String>,
    max_uses: Option<i64>,
    ttl_hours: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct UserStatusRequest {
    status: String,
}

#[derive(Debug, Deserialize)]
struct DeviceRequest {
    name: String,
    platform: String,
    address: String,
    fingerprint: String,
    capabilities: Option<Value>,
}

#[derive(Debug, Deserialize)]
struct ClaimRequest {
    code: String,
}

#[derive(Debug, Deserialize)]
struct TicketRequest {
    nonce: String,
    #[serde(default = "default_session_mode", alias = "engine")]
    mode: String,
}

fn default_session_mode() -> String {
    "tiles".to_string()
}

fn require_supported_session_mode(mode: &str) -> Result<(), ApiError> {
    if !matches!(mode, "tiles" | "flow" | "quality") {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "unsupported_mode",
            "Unknown session mode; supported: tiles, flow, quality.",
        ));
    }
    Ok(())
}

#[derive(Debug, Deserialize)]
struct SessionReport {
    session_id: String,
    user_id: i64,
    /// Final permissions after intersecting the ticket with Host local policy.
    permissions: u32,
    #[serde(default)]
    ticket_permissions: Option<u32>,
    #[serde(default)]
    host_instance: Option<String>,
    #[serde(default)]
    request_input: Option<bool>,
    #[serde(default)]
    input_allowed: Option<bool>,
    #[serde(default)]
    path: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SessionEndRequest {
    #[serde(default)]
    reason: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RevokeSessionsRequest {
    session_id: Option<String>,
}

#[derive(Debug, Clone)]
struct TicketRow {
    device_id: String,
    user_id: i64,
    permissions: u32,
    expires_at: i64,
    revoked: bool,
    started_at: Option<i64>,
}

const PRESENCE_ONLINE_SECS: i64 = 5;
const SESSION_ACTIVE_SECS: i64 = 10;
const SESSION_LEASE_SECS: i64 = 30;

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn random_hex(bytes: usize) -> String {
    let mut value = vec![0u8; bytes];
    thread_rng().fill(&mut value[..]);
    hex::encode(value)
}

fn random_code(len: usize) -> String {
    thread_rng()
        .sample_iter(&Alphanumeric)
        .take(len)
        .map(char::from)
        .collect::<String>()
        .to_uppercase()
}

fn validate_username(username: &str) -> Result<(), ApiError> {
    if username.len() < 3 || username.len() > 64 {
        return Err(ApiError::bad("username must be 3-64 characters"));
    }
    if !username
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
    {
        return Err(ApiError::bad(
            "username may contain letters, digits, underscore, dash and dot",
        ));
    }
    Ok(())
}

fn validate_password(password: &str) -> Result<(), ApiError> {
    if password.len() < 10 || password.len() > 256 {
        return Err(ApiError::bad("password must be 10-256 characters"));
    }
    Ok(())
}

fn normalize_fingerprint(input: &str) -> Result<String, ApiError> {
    let cleaned: String = input
        .chars()
        .filter(|c| c.is_ascii_hexdigit())
        .collect::<String>()
        .to_ascii_lowercase();
    if cleaned.len() != 64 {
        return Err(ApiError::bad(
            "fingerprint must contain 64 hexadecimal characters",
        ));
    }
    Ok(cleaned)
}

fn hash_password(password: &str) -> Result<String, ApiError> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|hash| hash.to_string())
        .map_err(|error| ApiError::internal(format!("password hash: {error}")))
}

fn verify_password(hash: &str, password: &str) -> bool {
    PasswordHash::new(hash)
        .ok()
        .and_then(|parsed| {
            Argon2::default()
                .verify_password(password.as_bytes(), &parsed)
                .ok()
        })
        .is_some()
}

fn open_db(path: &Path) -> Result<Connection, ApiError> {
    let conn = Connection::open(path)
        .map_err(|error| ApiError::internal(format!("open database: {error}")))?;
    conn.execute_batch(
        r#"
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL,
            role TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'active',
            created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions (
            token_hash TEXT PRIMARY KEY,
            user_id INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            revoked INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS invites (
            code TEXT PRIMARY KEY,
            role TEXT NOT NULL,
            max_uses INTEGER NOT NULL,
            used INTEGER NOT NULL DEFAULT 0,
            expires_at INTEGER NOT NULL,
            created_by INTEGER,
            created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS devices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            owner_id INTEGER NOT NULL,
            platform TEXT NOT NULL,
            address TEXT NOT NULL,
            fingerprint TEXT NOT NULL,
            capabilities TEXT NOT NULL DEFAULT '{}',
            status TEXT NOT NULL DEFAULT 'active',
            last_seen INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            device_token_hash TEXT NOT NULL,
            notes TEXT NOT NULL DEFAULT '',
            last_agent_seen INTEGER NOT NULL DEFAULT 0,
            agent_instance TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS device_grants (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id TEXT NOT NULL,
            user_id INTEGER NOT NULL,
            permissions TEXT NOT NULL,
            expires_at INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            UNIQUE(device_id, user_id)
        );
        CREATE TABLE IF NOT EXISTS pairing_codes (
            code TEXT PRIMARY KEY,
            device_id TEXT NOT NULL,
            created_by INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            used INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS audit (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            actor_id INTEGER,
            action TEXT NOT NULL,
            target TEXT,
            detail TEXT,
            created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS ticket_keys (
            kid TEXT PRIMARY KEY,
            private_pkcs8 TEXT NOT NULL,
            public_key TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            active INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS active_sessions (
            session_id TEXT PRIMARY KEY,
            device_id TEXT NOT NULL,
            user_id INTEGER NOT NULL,
            permissions INTEGER NOT NULL,
            started_at INTEGER NOT NULL,
            last_seen INTEGER NOT NULL,
            ended_at INTEGER,
            revoked INTEGER NOT NULL DEFAULT 0,
            ticket_permissions INTEGER NOT NULL DEFAULT 0,
            host_instance TEXT NOT NULL DEFAULT '',
            request_input INTEGER NOT NULL DEFAULT 0,
            input_allowed INTEGER NOT NULL DEFAULT 0,
            path TEXT NOT NULL DEFAULT 'direct_tcp_tls',
            end_reason TEXT
        );
        CREATE INDEX IF NOT EXISTS active_sessions_device
            ON active_sessions(device_id, ended_at, revoked);
        CREATE TABLE IF NOT EXISTS session_tickets (
            jti TEXT PRIMARY KEY,
            device_id TEXT NOT NULL,
            user_id INTEGER NOT NULL,
            permissions INTEGER NOT NULL,
            issued_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            revoked INTEGER NOT NULL DEFAULT 0,
            revoked_at INTEGER,
            started_at INTEGER
        );
        CREATE INDEX IF NOT EXISTS session_tickets_device
            ON session_tickets(device_id, revoked, expires_at);
        "#,
    )
    .map_err(|error| ApiError::internal(format!("initialize schema: {error}")))?;
    // Existing 0.2.0 databases predate these columns; add them in place.
    ensure_column(&conn, "devices", "notes", "TEXT NOT NULL DEFAULT ''")?;
    ensure_column(
        &conn,
        "devices",
        "last_agent_seen",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    ensure_column(
        &conn,
        "devices",
        "agent_instance",
        "TEXT NOT NULL DEFAULT ''",
    )?;
    ensure_column(
        &conn,
        "active_sessions",
        "ticket_permissions",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    ensure_column(
        &conn,
        "active_sessions",
        "host_instance",
        "TEXT NOT NULL DEFAULT ''",
    )?;
    ensure_column(
        &conn,
        "active_sessions",
        "request_input",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    ensure_column(
        &conn,
        "active_sessions",
        "input_allowed",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    ensure_column(
        &conn,
        "active_sessions",
        "path",
        "TEXT NOT NULL DEFAULT 'direct_tcp_tls'",
    )?;
    ensure_column(&conn, "active_sessions", "end_reason", "TEXT")?;
    Ok(conn)
}

fn ensure_column(
    conn: &Connection,
    table: &str,
    column: &str,
    definition: &str,
) -> Result<(), ApiError> {
    let mut statement = conn
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|error| ApiError::internal(format!("inspect {table}: {error}")))?;
    let existing = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|error| ApiError::internal(format!("inspect {table}: {error}")))?
        .filter_map(Result::ok)
        .any(|name| name == column);
    drop(statement);
    if !existing {
        conn.execute(
            &format!("ALTER TABLE {table} ADD COLUMN {column} {definition}"),
            [],
        )
        .map_err(|error| ApiError::internal(format!("add {table}.{column}: {error}")))?;
    }
    Ok(())
}

fn ensure_ticket_key(conn: &Connection) -> Result<TicketKeyMaterial, ApiError> {
    let rotate = env::var("YUANLIAN_ROTATE_TICKET_KEY")
        .map(|value| value == "1")
        .unwrap_or(false);
    if !rotate {
        let existing: Option<(String, String)> = conn
            .query_row(
                "SELECT kid, private_pkcs8 FROM ticket_keys WHERE active = 1
                 ORDER BY created_at DESC LIMIT 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(|error| ApiError::internal(format!("read ticket key: {error}")))?;
        if let Some((kid, private_hex)) = existing {
            let private_pkcs8 = hex::decode(private_hex)
                .map_err(|_| ApiError::internal("stored ticket key is not valid hex"))?;
            let parsed = ticket_key_from_pkcs8(&private_pkcs8)
                .map_err(|error| ApiError::internal(format!("parse ticket key: {error}")))?;
            if parsed.kid != kid {
                return Err(ApiError::internal(
                    "stored ticket key id does not match its key material",
                ));
            }
            return Ok(TicketKeyMaterial { kid, private_pkcs8 });
        }
    }
    let (private_pkcs8, kid, public_key) = generate_ticket_key()
        .map_err(|error| ApiError::internal(format!("generate ticket key: {error}")))?;
    conn.execute("UPDATE ticket_keys SET active = 0", [])
        .map_err(|error| ApiError::internal(format!("retire ticket keys: {error}")))?;
    conn.execute(
        "INSERT INTO ticket_keys (kid, private_pkcs8, public_key, created_at, active)
         VALUES (?1, ?2, ?3, ?4, 1)",
        params![
            kid,
            hex::encode(&private_pkcs8),
            hex::encode(&public_key),
            now()
        ],
    )
    .map_err(|error| ApiError::internal(format!("store ticket key: {error}")))?;
    Ok(TicketKeyMaterial { kid, private_pkcs8 })
}

fn audit(
    conn: &Connection,
    actor_id: Option<i64>,
    action: &str,
    target: Option<&str>,
    detail: Option<&str>,
) {
    let _ = conn.execute(
        "INSERT INTO audit (actor_id, action, target, detail, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![actor_id, action, target, detail, now()],
    );
}

fn create_session(conn: &Connection, user_id: i64) -> Result<(String, i64), ApiError> {
    let token = random_hex(32);
    let token_hash = sha256_hex(token.as_bytes());
    let expires = now() + SESSION_TTL_SECS;
    conn.execute(
        "INSERT INTO sessions (token_hash, user_id, created_at, expires_at, revoked) VALUES (?1, ?2, ?3, ?4, 0)",
        params![token_hash, user_id, now(), expires],
    )
    .map_err(|error| ApiError::internal(format!("create session: {error}")))?;
    Ok((token, expires))
}

fn bearer(headers: &HeaderMap) -> Option<String> {
    headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn authenticate(state: &AppState, headers: &HeaderMap) -> Result<AuthUser, ApiError> {
    let token = bearer(headers).ok_or_else(|| ApiError::unauthorized("missing bearer token"))?;
    let token_hash = sha256_hex(token.as_bytes());
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let user = conn
        .query_row(
            "SELECT u.id, u.username, u.role FROM sessions s JOIN users u ON u.id = s.user_id
             WHERE s.token_hash = ?1 AND s.revoked = 0 AND s.expires_at > ?2 AND u.status = 'active'",
            params![token_hash, now()],
            |row| {
                Ok(AuthUser {
                    id: row.get(0)?,
                    username: row.get(1)?,
                    role: row.get(2)?,
                })
            },
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read session: {error}")))?;
    user.ok_or_else(|| ApiError::unauthorized("session is invalid or expired"))
}

fn require_admin(user: &AuthUser) -> Result<(), ApiError> {
    if user.role != "admin" {
        return Err(ApiError::forbidden("administrator role required"));
    }
    Ok(())
}

async fn health(State(state): State<AppState>) -> Json<Value> {
    let db_ok = state
        .db
        .lock()
        .map(|conn| conn.execute_batch("SELECT 1;").is_ok())
        .unwrap_or(false);
    Json(json!({"ok": db_ok, "version": env!("CARGO_PKG_VERSION")}))
}

async fn server_info(State(state): State<AppState>) -> Result<Json<Value>, ApiError> {
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let users: i64 = conn
        .query_row("SELECT COUNT(*) FROM users", [], |row| row.get(0))
        .map_err(|error| ApiError::internal(format!("count users: {error}")))?;
    let name: String = conn
        .query_row(
            "SELECT value FROM settings WHERE key = 'server_name'",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read settings: {error}")))?
        .unwrap_or_else(|| "YuanLian Internal".to_string());
    Ok(Json(json!({
        "name": name,
        "version": env!("CARGO_PKG_VERSION"),
        "initialized": users > 0,
        "users": users,
        "features": ["accounts", "invites", "sessions", "devices", "pairing", "grants", "admin"],
        "session_modes": ["tiles", "flow", "quality"],
        "quality_streaming": {"supported": true, "requires": "host_v3_dedicated_sunshine", "embedded": false},
        "tls": false,
        "note": "Bind loopback and terminate TLS at a reverse proxy before exposure."
    })))
}

async fn admin_page() -> Html<&'static str> {
    Html(ADMIN_HTML)
}

fn constant_time_eq(left: &str, right: &str) -> bool {
    let left = left.as_bytes();
    let right = right.as_bytes();
    if left.len() != right.len() {
        return false;
    }
    let mut different = 0u8;
    for (a, b) in left.iter().zip(right.iter()) {
        different |= a ^ b;
    }
    different == 0
}

fn permission_bits(value: &Value) -> u32 {
    let mut bits = 0;
    for item in value.as_array().into_iter().flatten() {
        match item.as_str() {
            Some("view") => bits |= PERMISSION_VIEW,
            Some("control") => bits |= PERMISSION_CONTROL,
            Some("file_read") => bits |= PERMISSION_FILE_READ,
            Some("file_write") => bits |= PERMISSION_FILE_WRITE,
            Some("file_delete") => bits |= PERMISSION_FILE_DELETE,
            _ => {}
        }
    }
    bits
}

/// Validates the device token and reports whether the device and its owner are
/// still active. A valid token for a revoked device is accepted here so the
/// Host receives a clear revocation instead of an opaque authentication error.
fn authenticate_device_token(
    conn: &Connection,
    headers: &HeaderMap,
    device_id: &str,
) -> Result<(bool, bool), ApiError> {
    let token = headers
        .get("x-device-token")
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| ApiError::unauthorized("x-device-token is required"))?;
    let presented = sha256_hex(token.as_bytes());
    let row: Option<(String, i64, String)> = conn
        .query_row(
            "SELECT device_token_hash, owner_id, status FROM devices WHERE device_id = ?1",
            params![device_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read device token: {error}")))?;
    let Some((stored_hash, owner_id, status)) = row else {
        return Err(ApiError::not_found("device is not registered"));
    };
    if !constant_time_eq(&presented, &stored_hash) {
        return Err(ApiError::unauthorized("device token is invalid"));
    }
    let owner_status: Option<String> = conn
        .query_row(
            "SELECT status FROM users WHERE id = ?1",
            params![owner_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read device owner: {error}")))?;
    let device_active = status == "active";
    let owner_active = owner_status.as_deref() == Some("active");
    Ok((device_active && owner_active, device_active))
}

fn read_ticket(
    conn: &Connection,
    device_id: &str,
    jti: &str,
) -> Result<Option<TicketRow>, ApiError> {
    conn.query_row(
        "SELECT device_id, user_id, permissions, expires_at, revoked, started_at
         FROM session_tickets WHERE jti = ?1 AND device_id = ?2",
        params![jti, device_id],
        |row| {
            Ok(TicketRow {
                device_id: row.get(0)?,
                user_id: row.get(1)?,
                permissions: row.get(2)?,
                expires_at: row.get(3)?,
                revoked: row.get::<_, i64>(4)? == 1,
                started_at: row.get(5)?,
            })
        },
    )
    .optional()
    .map_err(|error| ApiError::internal(format!("read session ticket: {error}")))
}

/// Checks current account/device/grant state for a ticket. This is evaluated
/// at connection time and again when the Host starts a session, so disabling a
/// user, revoking a device or expiring a share also invalidates pending
/// tickets, not only sessions already in the active table.
fn ticket_authorization(
    conn: &Connection,
    ticket: &TicketRow,
) -> Result<(bool, &'static str), ApiError> {
    let device: Option<(i64, String)> = conn
        .query_row(
            "SELECT owner_id, status FROM devices WHERE device_id = ?1",
            params![ticket.device_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read ticket device: {error}")))?;
    let Some((owner_id, device_status)) = device else {
        return Ok((false, "device_missing"));
    };
    if device_status != "active" {
        return Ok((false, "device_revoked"));
    }
    let user: Option<(String, String)> = conn
        .query_row(
            "SELECT status, role FROM users WHERE id = ?1",
            params![ticket.user_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read ticket user: {error}")))?;
    let Some((user_status, role)) = user else {
        return Ok((false, "user_missing"));
    };
    if user_status != "active" {
        return Ok((false, "user_disabled"));
    }
    let owner_status: Option<String> = conn
        .query_row(
            "SELECT status FROM users WHERE id = ?1",
            params![owner_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read ticket owner: {error}")))?;
    if owner_status.as_deref() != Some("active") {
        return Ok((false, "owner_disabled"));
    }
    if role == "admin" || ticket.user_id == owner_id {
        return Ok((true, "owner"));
    }
    let grant: Option<(String, i64)> = conn
        .query_row(
            "SELECT permissions, expires_at FROM device_grants
             WHERE device_id = ?1 AND user_id = ?2",
            params![ticket.device_id, ticket.user_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read ticket grant: {error}")))?;
    let Some((permissions, expires_at)) = grant else {
        return Ok((false, "grant_missing"));
    };
    if expires_at != 0 && expires_at <= now() {
        return Ok((false, "grant_expired"));
    }
    let parsed = serde_json::from_str::<Value>(&permissions).unwrap_or(Value::String(permissions));
    let grant_bits = permission_bits(&parsed);
    if grant_bits & ticket.permissions != ticket.permissions {
        return Ok((false, "grant_reduced"));
    }
    Ok((true, "grant"))
}

async fn ticket_status(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath((device_id, jti)): AxumPath<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let (device_active, _) = authenticate_device_token(&conn, &headers, &device_id)?;
    let ticket = read_ticket(&conn, &device_id, &jti)?
        .ok_or_else(|| ApiError::not_found("session ticket not found for this device"))?;
    let (authorized, reason) = ticket_authorization(&conn, &ticket)?;
    let mut valid = device_active && authorized && !ticket.revoked && ticket.expires_at > now();
    let mut reason = reason;
    if ticket.revoked {
        valid = false;
        reason = "ticket_revoked";
    } else if ticket.expires_at <= now() {
        valid = false;
        reason = "ticket_expired";
    } else if ticket.started_at.is_some() {
        valid = false;
        reason = "ticket_already_started";
    }
    Ok(Json(json!({
        "valid": valid,
        "reason": reason,
        "revoked": ticket.revoked,
        "started_at": ticket.started_at,
        "expires_at": ticket.expires_at,
        "device_active": device_active,
        "server_now": now(),
    })))
}

async fn ticket_keys(State(state): State<AppState>) -> Result<Json<Value>, ApiError> {
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let mut stmt = conn
        .prepare("SELECT kid, public_key, active, created_at FROM ticket_keys ORDER BY created_at")
        .map_err(|error| ApiError::internal(format!("prepare ticket keys: {error}")))?;
    let keys = stmt
        .query_map([], |row| {
            Ok(json!({
                "kid": row.get::<_, String>(0)?,
                "public_key": row.get::<_, String>(1)?,
                "alg": "Ed25519",
                "active": row.get::<_, i64>(2)? == 1,
                "created_at": row.get::<_, i64>(3)?,
            }))
        })
        .map_err(|error| ApiError::internal(format!("list ticket keys: {error}")))?
        .filter_map(Result::ok)
        .collect::<Vec<_>>();
    Ok(Json(json!({"keys": keys})))
}

async fn issue_session_ticket(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(device_id): AxumPath<String>,
    Json(request): Json<TicketRequest>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    require_supported_session_mode(&request.mode)?;
    let nonce = request.nonce.trim();
    if nonce.len() != 64 || !nonce.chars().all(|character| character.is_ascii_hexdigit()) {
        return Err(ApiError::bad(
            "nonce must be 64 hexadecimal characters generated by the viewer",
        ));
    }
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let device = device_json(&conn, &device_id, actor.id, &actor.role)?;
    if device["status"] != "active" {
        return Err(ApiError::conflict("device is not active"));
    }
    let owner_id = device["owner_id"]
        .as_i64()
        .ok_or_else(|| ApiError::internal("device owner id missing"))?;
    let owner_status: Option<String> = conn
        .query_row(
            "SELECT status FROM users WHERE id = ?1",
            params![owner_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read device owner: {error}")))?;
    if owner_status.as_deref() != Some("active") {
        return Err(ApiError::forbidden("device owner account is disabled"));
    }
    let permissions = if actor.role == "admin" || actor.id == owner_id {
        PERMISSION_ALL
    } else {
        permission_bits(&device["grant"]["permissions"])
    };
    if permissions & PERMISSION_VIEW == 0 {
        return Err(ApiError::forbidden(
            "grant does not include view permission",
        ));
    }
    let issued_at = now();
    let claims = SessionClaims {
        v: TICKET_VERSION,
        kid: state.ticket_key.kid.clone(),
        aud: device_id.clone(),
        sub: actor.id,
        user: actor.username.clone(),
        jti: random_hex(16),
        purpose: TICKET_PURPOSE.to_string(),
        mode: request.mode.clone(),
        nonce_sha256: nonce_sha256(nonce),
        permissions,
        iat: issued_at,
        exp: issued_at + SESSION_TICKET_TTL_SECS,
    };
    let ticket = sign_ticket(&state.ticket_key.private_pkcs8, &claims)
        .map_err(|error| ApiError::internal(format!("sign session ticket: {error}")))?;
    conn.execute(
        "INSERT INTO session_tickets
            (jti, device_id, user_id, permissions, issued_at, expires_at, revoked, revoked_at, started_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, NULL, NULL)",
        params![
            claims.jti,
            device_id,
            actor.id,
            permissions,
            issued_at,
            claims.exp
        ],
    )
    .map_err(|error| ApiError::internal(format!("store session ticket: {error}")))?;
    audit(
        &conn,
        Some(actor.id),
        "session.ticket",
        Some(&device_id),
        Some(&claims.jti),
    );
    Ok(Json(json!({
        "ticket": ticket,
        "session_id": claims.jti,
        "expires_at": claims.exp,
        "permissions": permissions,
        "permission_names": yl_proto::permission_summary(permissions),
        "device_id": device["device_id"],
        "name": device["name"],
        "address": device["address"],
        "fingerprint": device["fingerprint"],
    })))
}

async fn report_session_start(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(device_id): AxumPath<String>,
    Json(report): Json<SessionReport>,
) -> Result<Json<Value>, ApiError> {
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let (active, _) = authenticate_device_token(&conn, &headers, &device_id)?;
    if !active {
        return Err(ApiError::forbidden("device or owner is not active"));
    }
    if !valid_session_id(&report.session_id) {
        return Err(ApiError::bad("invalid session id"));
    }
    if report.permissions & !PERMISSION_ALL != 0 {
        return Err(ApiError::bad("invalid permission bits"));
    }
    if report.permissions & PERMISSION_VIEW == 0 {
        return Err(ApiError::bad("session must include view permission"));
    }
    let host_instance = report.host_instance.as_deref().unwrap_or("").trim();
    if host_instance.len() > 64
        || !host_instance
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_'))
    {
        return Err(ApiError::bad("invalid host instance id"));
    }
    let request_input = report.request_input.unwrap_or(true);
    let input_allowed = report.input_allowed.unwrap_or(false);
    if input_allowed && (!request_input || report.permissions & PERMISSION_CONTROL == 0) {
        return Err(ApiError::bad(
            "input_allowed requires requested control permission",
        ));
    }
    let path = report.path.as_deref().unwrap_or("direct_tcp_tls");
    if path.len() > 64
        || !path
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '_')
    {
        return Err(ApiError::bad("invalid transport path"));
    }

    let ticket = read_ticket(&conn, &device_id, &report.session_id)?
        .ok_or_else(|| ApiError::forbidden("session ticket was not issued by this server"))?;
    if ticket.user_id != report.user_id {
        return Err(ApiError::conflict(
            "session ticket belongs to a different user",
        ));
    }
    if ticket.revoked {
        return Err(ApiError::conflict("session ticket has been revoked"));
    }
    if ticket.expires_at <= now() {
        return Err(ApiError::conflict("session ticket has expired"));
    }
    if report.permissions & !ticket.permissions != 0 {
        return Err(ApiError::forbidden(
            "effective permissions exceed the ticket",
        ));
    }
    if let Some(claimed) = report.ticket_permissions {
        if claimed != ticket.permissions {
            return Err(ApiError::bad(
                "ticket_permissions does not match the issued ticket",
            ));
        }
    }
    let (authorized, reason) = ticket_authorization(&conn, &ticket)?;
    if !authorized {
        return Err(ApiError::forbidden(format!(
            "session authorization is no longer valid: {reason}"
        )));
    }

    let existing: Option<(String, i64, Option<i64>, i64, String)> = conn
        .query_row(
            "SELECT device_id, user_id, ended_at, revoked, host_instance
             FROM active_sessions WHERE session_id = ?1",
            params![report.session_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read existing session: {error}")))?;
    let timestamp = now();
    if let Some((existing_device, existing_user, ended_at, revoked, existing_instance)) = existing {
        if existing_device != device_id || existing_user != report.user_id {
            return Err(ApiError::conflict(
                "session id already belongs to another device or user",
            ));
        }
        if ended_at.is_some() {
            return Err(ApiError::conflict("session is already in a terminal state"));
        }
        if revoked != 0 {
            return Err(ApiError::conflict("session has been revoked"));
        }
        if !host_instance.is_empty()
            && !existing_instance.is_empty()
            && existing_instance != host_instance
        {
            return Err(ApiError::conflict(
                "session id is bound to another Host instance",
            ));
        }
        conn.execute(
            "UPDATE active_sessions SET permissions = ?1, ticket_permissions = ?2,
                request_input = ?3, input_allowed = ?4, path = ?5, last_seen = ?6
             WHERE session_id = ?7 AND ended_at IS NULL",
            params![
                report.permissions,
                ticket.permissions,
                request_input as i64,
                input_allowed as i64,
                path,
                timestamp,
                report.session_id
            ],
        )
        .map_err(|error| ApiError::internal(format!("refresh session: {error}")))?;
        return Ok(Json(json!({
            "ok": true,
            "session_id": report.session_id,
            "state": "active",
            "revoked": false,
            "server_now": timestamp,
        })));
    }

    // A new Host process ended any previous business session on this device.
    if !host_instance.is_empty() {
        conn.execute(
            "UPDATE active_sessions SET ended_at = ?1, end_reason = 'host_restarted'
             WHERE device_id = ?2 AND ended_at IS NULL AND host_instance <> ''
               AND host_instance <> ?3",
            params![timestamp, device_id, host_instance],
        )
        .map_err(|error| ApiError::internal(format!("reconcile host sessions: {error}")))?;
    }

    let tx = conn
        .unchecked_transaction()
        .map_err(|error| ApiError::internal(format!("start session transaction: {error}")))?;
    tx.execute(
        "UPDATE session_tickets SET started_at = COALESCE(started_at, ?1)
         WHERE jti = ?2 AND device_id = ?3 AND revoked = 0",
        params![timestamp, report.session_id, device_id],
    )
    .map_err(|error| ApiError::internal(format!("mark ticket started: {error}")))?;
    tx.execute(
        "INSERT INTO active_sessions
            (session_id, device_id, user_id, permissions, started_at, last_seen, ended_at, revoked,
             ticket_permissions, host_instance, request_input, input_allowed, path, end_reason)
         VALUES (?1, ?2, ?3, ?4, ?5, ?5, NULL, 0, ?6, ?7, ?8, ?9, ?10, NULL)",
        params![
            report.session_id,
            device_id,
            report.user_id,
            report.permissions,
            timestamp,
            ticket.permissions,
            host_instance,
            request_input as i64,
            input_allowed as i64,
            path
        ],
    )
    .map_err(|error| ApiError::internal(format!("record session start: {error}")))?;
    audit(
        &tx,
        Some(report.user_id),
        "session.start",
        Some(&device_id),
        Some(&report.session_id),
    );
    tx.commit()
        .map_err(|error| ApiError::internal(format!("commit session start: {error}")))?;
    Ok(Json(json!({
        "ok": true,
        "session_id": report.session_id,
        "state": "active",
        "revoked": false,
        "server_now": timestamp,
    })))
}

fn valid_session_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_'))
}

async fn report_session_end(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath((device_id, session_id)): AxumPath<(String, String)>,
    Json(request): Json<SessionEndRequest>,
) -> Result<Json<Value>, ApiError> {
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    // A valid device token may confirm its own session end even after the
    // device was revoked; this is what lets the UI distinguish "revocation
    // requested" from "endpoint confirmed". It cannot create sessions.
    let _ = authenticate_device_token(&conn, &headers, &device_id)?;
    if !valid_session_id(&session_id) {
        return Err(ApiError::bad("invalid session id"));
    }
    let reason = request.reason.as_deref().unwrap_or("host_ended");
    if reason.len() > 64
        || !reason
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '_')
    {
        return Err(ApiError::bad("invalid end reason"));
    }
    let timestamp = now();
    let changed = conn
        .execute(
            "UPDATE active_sessions SET ended_at = ?1, end_reason = ?2
             WHERE session_id = ?3 AND device_id = ?4 AND ended_at IS NULL",
            params![timestamp, reason, session_id, device_id],
        )
        .map_err(|error| ApiError::internal(format!("record session end: {error}")))?;
    if changed == 0 {
        conn.execute(
            "INSERT OR IGNORE INTO active_sessions
                (session_id, device_id, user_id, permissions, started_at, last_seen, ended_at, revoked,
                 ticket_permissions, host_instance, request_input, input_allowed, path, end_reason)
             VALUES (?1, ?2, 0, 0, ?3, ?3, ?3, 0, 0, '', 0, 0, 'unknown', ?4)",
            params![session_id, device_id, timestamp, reason],
        )
        .map_err(|error| ApiError::internal(format!("record session tombstone: {error}")))?;
    }
    audit(
        &conn,
        None,
        "session.end",
        Some(&device_id),
        Some(&session_id),
    );
    Ok(Json(json!({"ok": true, "server_now": timestamp})))
}

async fn list_sessions(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(device_id): AxumPath<String>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let owner: Option<i64> = conn
        .query_row(
            "SELECT owner_id FROM devices WHERE device_id = ?1",
            params![device_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read device owner: {error}")))?;
    let Some(owner_id) = owner else {
        return Err(ApiError::not_found("device not found"));
    };
    if owner_id != actor.id && actor.role != "admin" {
        return Err(ApiError::forbidden("only owner can list device sessions"));
    }
    let now_v = now();
    let mut stmt = conn
        .prepare(
            "SELECT s.session_id, s.user_id, u.username, s.permissions, s.started_at,
                    s.last_seen, s.revoked, s.ended_at, s.ticket_permissions,
                    s.host_instance, s.request_input, s.input_allowed, s.path, s.end_reason
             FROM active_sessions s LEFT JOIN users u ON u.id = s.user_id
             WHERE s.device_id = ?1 AND s.ended_at IS NULL ORDER BY s.started_at DESC",
        )
        .map_err(|error| ApiError::internal(format!("prepare sessions: {error}")))?;
    let sessions = stmt
        .query_map(params![device_id], |row| {
            let last_seen: i64 = row.get(5)?;
            let revoked = row.get::<_, i64>(6)? == 1;
            let ended_at: Option<i64> = row.get(7)?;
            let state = session_state(now_v, last_seen, ended_at, revoked);
            Ok(json!({
                "session_id": row.get::<_, String>(0)?,
                "user_id": row.get::<_, i64>(1)?,
                "user": row.get::<_, Option<String>>(2)?,
                "permissions": row.get::<_, i64>(3)?,
                "permission_names": yl_proto::permission_summary(row.get::<_, i64>(3)? as u32),
                "started_at": row.get::<_, i64>(4)?,
                "last_seen": last_seen,
                "revoked": revoked,
                "state": state,
                "ended_at": ended_at,
                "ticket_permissions": row.get::<_, i64>(8)?,
                "host_instance": row.get::<_, String>(9)?,
                "request_input": row.get::<_, i64>(10)? == 1,
                "input_allowed": row.get::<_, i64>(11)? == 1,
                "path": row.get::<_, String>(12)?,
                "end_reason": row.get::<_, Option<String>>(13)?,
            }))
        })
        .map_err(|error| ApiError::internal(format!("list sessions: {error}")))?
        .filter_map(Result::ok)
        .collect::<Vec<_>>();
    Ok(Json(json!({"sessions": sessions, "server_now": now_v})))
}

fn session_state(now_v: i64, last_seen: i64, ended_at: Option<i64>, revoked: bool) -> &'static str {
    if ended_at.is_some() {
        return "ended";
    }
    if revoked {
        return "revoking";
    }
    let age = now_v.saturating_sub(last_seen);
    if age > SESSION_LEASE_SECS {
        "stale"
    } else if age > SESSION_ACTIVE_SECS {
        "unknown"
    } else {
        "active"
    }
}

async fn revoke_sessions(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(device_id): AxumPath<String>,
    Json(request): Json<RevokeSessionsRequest>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let owner: Option<i64> = conn
        .query_row(
            "SELECT owner_id FROM devices WHERE device_id = ?1",
            params![device_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read device owner: {error}")))?;
    let Some(owner_id) = owner else {
        return Err(ApiError::not_found("device not found"));
    };
    if owner_id != actor.id && actor.role != "admin" {
        return Err(ApiError::forbidden("only owner can revoke sessions"));
    }
    let changed = if let Some(session_id) = request.session_id.as_deref() {
        conn.execute(
            "UPDATE active_sessions SET revoked = 1
             WHERE device_id = ?1 AND session_id = ?2 AND ended_at IS NULL",
            params![device_id, session_id],
        )
        .map_err(|error| ApiError::internal(format!("revoke session: {error}")))?
    } else {
        conn.execute(
            "UPDATE active_sessions SET revoked = 1
             WHERE device_id = ?1 AND ended_at IS NULL",
            params![device_id],
        )
        .map_err(|error| ApiError::internal(format!("revoke sessions: {error}")))?
    };
    audit(
        &conn,
        Some(actor.id),
        "session.revoke",
        Some(&device_id),
        request.session_id.as_deref(),
    );
    Ok(Json(json!({"ok": true, "revoked": changed})))
}

async fn setup(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(request): Json<SetupRequest>,
) -> Result<Json<Value>, ApiError> {
    if !addr.ip().is_loopback() {
        return Err(ApiError::forbidden(
            "initial setup is only allowed from loopback",
        ));
    }
    validate_username(&request.username)?;
    validate_password(&request.password)?;
    let server_name = request
        .server_name
        .unwrap_or_else(|| "YuanLian Internal".to_string());
    if server_name.trim().is_empty() || server_name.len() > 80 {
        return Err(ApiError::bad("server name must be 1-80 characters"));
    }
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM users", [], |row| row.get(0))
        .map_err(|error| ApiError::internal(format!("count users: {error}")))?;
    if count > 0 {
        return Err(ApiError::conflict("server is already initialized"));
    }
    let password_hash = hash_password(&request.password)?;
    conn.execute(
        "INSERT INTO users (username, password_hash, role, status, created_at) VALUES (?1, ?2, 'admin', 'active', ?3)",
        params![request.username, password_hash, now()],
    )
    .map_err(|error| ApiError::internal(format!("create admin: {error}")))?;
    let user_id = conn.last_insert_rowid();
    conn.execute(
        "INSERT INTO settings (key, value) VALUES ('server_name', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![server_name],
    )
    .map_err(|error| ApiError::internal(format!("save server name: {error}")))?;
    let (token, expires) = create_session(&conn, user_id)?;
    audit(&conn, Some(user_id), "setup", None, None);
    Ok(Json(json!({
        "token": token,
        "expires_at": expires,
        "user": {"id": user_id, "username": request.username, "role": "admin"}
    })))
}

async fn login(
    State(state): State<AppState>,
    Json(request): Json<LoginRequest>,
) -> Result<Json<Value>, ApiError> {
    let now_v = now();
    {
        let guard = state
            .login_guard
            .lock()
            .map_err(|_| ApiError::internal("login guard poisoned"))?;
        if let Some((_, until)) = guard.get(&request.username) {
            if *until > now_v {
                return Err(ApiError::new(
                    StatusCode::TOO_MANY_REQUESTS,
                    "rate_limited",
                    "too many failed login attempts; try again later",
                ));
            }
        }
    }
    // Read the hash under the short-lived DB lock, release it, and run the
    // deliberately expensive Argon2 verification on the blocking pool. The
    // previous implementation held the single SQLite mutex during the hash,
    // serializing every device heartbeat and session request behind a login.
    let user: Option<(i64, String, String, String, String)> = {
        let conn = state
            .db
            .lock()
            .map_err(|_| ApiError::internal("database lock poisoned"))?;
        conn.query_row(
            "SELECT id, username, password_hash, role, status FROM users WHERE username = ?1",
            params![request.username],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read login user: {error}")))?
    };
    let Some((id, username, password_hash, role, status)) = user else {
        increment_login_failure(&state, &request.username, now_v)?;
        return Err(ApiError::unauthorized("username or password is incorrect"));
    };
    if status != "active" {
        return Err(ApiError::forbidden("account is disabled"));
    }
    let password = request.password.clone();
    let password_ok =
        tokio::task::spawn_blocking(move || verify_password(&password_hash, &password))
            .await
            .map_err(|error| ApiError::internal(format!("password verification task: {error}")))?;
    if !password_ok {
        increment_login_failure(&state, &request.username, now_v)?;
        return Err(ApiError::unauthorized("username or password is incorrect"));
    }
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let current_status: Option<String> = conn
        .query_row(
            "SELECT status FROM users WHERE id = ?1",
            params![id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read user status: {error}")))?;
    if current_status.as_deref() != Some("active") {
        return Err(ApiError::forbidden("account is disabled"));
    }
    if let Ok(mut guard) = state.login_guard.lock() {
        guard.remove(&request.username);
    }
    let (token, expires) = create_session(&conn, id)?;
    audit(&conn, Some(id), "login", None, None);
    Ok(Json(json!({
        "token": token,
        "expires_at": expires,
        "user": {"id": id, "username": username, "role": role}
    })))
}

fn increment_login_failure(state: &AppState, username: &str, now_v: i64) -> Result<(), ApiError> {
    let mut guard = state
        .login_guard
        .lock()
        .map_err(|_| ApiError::internal("login guard poisoned"))?;
    let entry = guard.entry(username.to_string()).or_insert((0, 0));
    entry.0 += 1;
    if entry.0 >= 5 {
        entry.1 = now_v + 60;
        entry.0 = 0;
    }
    Ok(())
}

async fn logout(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let token = bearer(&headers).ok_or_else(|| ApiError::unauthorized("missing bearer token"))?;
    let token_hash = sha256_hex(token.as_bytes());
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let changed = conn
        .execute(
            "UPDATE sessions SET revoked = 1 WHERE token_hash = ?1",
            params![token_hash],
        )
        .map_err(|error| ApiError::internal(format!("revoke session: {error}")))?;
    if changed == 0 {
        return Err(ApiError::unauthorized("session is invalid"));
    }
    Ok(Json(json!({"ok": true})))
}

async fn refresh(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = authenticate(&state, &headers)?;
    let token = bearer(&headers).ok_or_else(|| ApiError::unauthorized("missing bearer token"))?;
    let old_hash = sha256_hex(token.as_bytes());
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    conn.execute(
        "UPDATE sessions SET revoked = 1 WHERE token_hash = ?1",
        params![old_hash],
    )
    .map_err(|error| ApiError::internal(format!("rotate session: {error}")))?;
    let (new_token, expires) = create_session(&conn, user.id)?;
    Ok(Json(json!({
        "token": new_token,
        "expires_at": expires,
        "user": {"id": user.id, "username": user.username, "role": user.role}
    })))
}

async fn change_password(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<PasswordRequest>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    validate_password(&request.new_password)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let current_hash: String = conn
        .query_row(
            "SELECT password_hash FROM users WHERE id=?1",
            params![actor.id],
            |row| row.get(0),
        )
        .map_err(|error| ApiError::internal(format!("read password: {error}")))?;
    if !verify_password(&current_hash, &request.current_password) {
        return Err(ApiError::unauthorized("current password is incorrect"));
    }
    let new_hash = hash_password(&request.new_password)?;
    conn.execute(
        "UPDATE users SET password_hash=?1 WHERE id=?2",
        params![new_hash, actor.id],
    )
    .map_err(|error| ApiError::internal(format!("update password: {error}")))?;
    conn.execute(
        "UPDATE sessions SET revoked=1 WHERE user_id=?1",
        params![actor.id],
    )
    .map_err(|error| ApiError::internal(format!("revoke sessions: {error}")))?;
    audit(&conn, Some(actor.id), "auth.password_change", None, None);
    Ok(Json(json!({"ok": true, "sessions_revoked": true})))
}

async fn me(State(state): State<AppState>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let user = authenticate(&state, &headers)?;
    Ok(Json(
        json!({"user": {"id": user.id, "username": user.username, "role": user.role}}),
    ))
}

async fn create_invite(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<InviteRequest>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    require_admin(&actor)?;
    let role = request.role.unwrap_or_else(|| "user".to_string());
    if role != "user" && role != "admin" {
        return Err(ApiError::bad("role must be user or admin"));
    }
    let max_uses = request.max_uses.unwrap_or(1).clamp(1, 100);
    let ttl_hours = request.ttl_hours.unwrap_or(24).clamp(1, 720);
    let code = random_code(10);
    let expires = now() + ttl_hours * 3600;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    conn.execute(
        "INSERT INTO invites (code, role, max_uses, used, expires_at, created_by, created_at)
         VALUES (?1, ?2, ?3, 0, ?4, ?5, ?6)",
        params![code, role, max_uses, expires, actor.id, now()],
    )
    .map_err(|error| ApiError::internal(format!("create invite: {error}")))?;
    audit(
        &conn,
        Some(actor.id),
        "invite.create",
        Some(&code),
        Some(&role),
    );
    Ok(Json(json!({
        "code": code,
        "role": role,
        "max_uses": max_uses,
        "expires_at": expires
    })))
}

async fn register_with_invite(
    State(state): State<AppState>,
    Json(request): Json<RegisterRequest>,
) -> Result<Json<Value>, ApiError> {
    validate_username(&request.username)?;
    validate_password(&request.password)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let invite: Option<(String, i64, i64, i64)> = conn
        .query_row(
            "SELECT role, max_uses, used, expires_at FROM invites WHERE code = ?1",
            params![request.invite_code],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read invite: {error}")))?;
    let Some((role, max_uses, used, expires_at)) = invite else {
        return Err(ApiError::not_found("invite code is invalid"));
    };
    if used >= max_uses {
        return Err(ApiError::conflict("invite code has already been used"));
    }
    if expires_at <= now() {
        return Err(ApiError::conflict("invite code has expired"));
    }
    let password_hash = hash_password(&request.password)?;
    let inserted = conn.execute(
        "INSERT INTO users (username, password_hash, role, status, created_at) VALUES (?1, ?2, ?3, 'active', ?4)",
        params![request.username, password_hash, role, now()],
    );
    if let Err(error) = inserted {
        return Err(ApiError::conflict(format!(
            "username is not available: {error}"
        )));
    }
    let user_id = conn.last_insert_rowid();
    conn.execute(
        "UPDATE invites SET used = used + 1 WHERE code = ?1",
        params![request.invite_code],
    )
    .map_err(|error| ApiError::internal(format!("consume invite: {error}")))?;
    let (token, expires) = create_session(&conn, user_id)?;
    audit(&conn, Some(user_id), "user.register", None, Some(&role));
    Ok(Json(json!({
        "token": token,
        "expires_at": expires,
        "user": {"id": user_id, "username": request.username, "role": role}
    })))
}

async fn list_users(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    require_admin(&actor)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let mut stmt = conn
        .prepare("SELECT id, username, role, status, created_at FROM users ORDER BY id")
        .map_err(|error| ApiError::internal(format!("prepare users: {error}")))?;
    let users = stmt
        .query_map([], |row| {
            Ok(json!({
                "id": row.get::<_, i64>(0)?,
                "username": row.get::<_, String>(1)?,
                "role": row.get::<_, String>(2)?,
                "status": row.get::<_, String>(3)?,
                "created_at": row.get::<_, i64>(4)?
            }))
        })
        .map_err(|error| ApiError::internal(format!("list users: {error}")))?
        .filter_map(Result::ok)
        .collect::<Vec<_>>();
    Ok(Json(json!({"users": users})))
}

async fn set_user_status(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(user_id): AxumPath<i64>,
    Json(request): Json<UserStatusRequest>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    require_admin(&actor)?;
    if user_id == actor.id {
        return Err(ApiError::conflict("administrator cannot disable itself"));
    }
    if request.status != "active" && request.status != "disabled" {
        return Err(ApiError::bad("status must be active or disabled"));
    }
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let changed = conn
        .execute(
            "UPDATE users SET status = ?1 WHERE id = ?2",
            params![request.status, user_id],
        )
        .map_err(|error| ApiError::internal(format!("set user status: {error}")))?;
    if changed == 0 {
        return Err(ApiError::not_found("user not found"));
    }
    if request.status == "disabled" {
        conn.execute(
            "UPDATE sessions SET revoked = 1 WHERE user_id = ?1",
            params![user_id],
        )
        .map_err(|error| ApiError::internal(format!("revoke user sessions: {error}")))?;
        conn.execute(
            "UPDATE active_sessions SET revoked = 1
             WHERE ended_at IS NULL AND (
                user_id = ?1 OR device_id IN (SELECT device_id FROM devices WHERE owner_id = ?1)
             )",
            params![user_id],
        )
        .map_err(|error| ApiError::internal(format!("revoke device sessions: {error}")))?;
        conn.execute(
            "UPDATE session_tickets SET revoked = 1, revoked_at = ?2
             WHERE revoked = 0 AND (
                user_id = ?1 OR device_id IN (SELECT device_id FROM devices WHERE owner_id = ?1)
             )",
            params![user_id, now()],
        )
        .map_err(|error| ApiError::internal(format!("revoke pending tickets: {error}")))?;
    }
    audit(
        &conn,
        Some(actor.id),
        "user.status",
        Some(&user_id.to_string()),
        Some(&request.status),
    );
    Ok(Json(json!({"ok": true})))
}

fn device_id_for(fingerprint: &str) -> String {
    let digest = sha256_hex(fingerprint.as_bytes());
    format!("yl-{}", &digest[..16])
}

fn device_json(
    conn: &Connection,
    device_id: &str,
    viewer_id: i64,
    viewer_role: &str,
) -> Result<Value, ApiError> {
    let mut stmt = conn
        .prepare(
            "SELECT d.device_id, d.name, d.owner_id, u.username, d.platform, d.address,
                    d.fingerprint, d.capabilities, d.status, d.last_seen, d.created_at,
                    d.notes, d.last_agent_seen, d.agent_instance
             FROM devices d JOIN users u ON u.id = d.owner_id WHERE d.device_id = ?1",
        )
        .map_err(|error| ApiError::internal(format!("prepare device: {error}")))?;
    let mut rows = stmt
        .query(params![device_id])
        .map_err(|error| ApiError::internal(format!("query device: {error}")))?;
    let row = rows
        .next()
        .map_err(|error| ApiError::internal(format!("read device: {error}")))?
        .ok_or_else(|| ApiError::not_found("device not found"))?;
    let owner_id: i64 = row.get(2).map_err(ApiError::internal)?;
    let grant: Option<(String, i64)> = conn
        .query_row(
            "SELECT permissions, expires_at FROM device_grants WHERE device_id = ?1 AND user_id = ?2",
            params![device_id, viewer_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read device grant: {error}")))?;
    let shared = owner_id != viewer_id;
    if shared && viewer_role != "admin" {
        match &grant {
            Some((_, expires_at)) if *expires_at == 0 || *expires_at > now() => {}
            _ => return Err(ApiError::forbidden("no access to this device")),
        }
    }
    let grant = grant.map(|(permissions, expires_at)| {
        let parsed =
            serde_json::from_str::<Value>(&permissions).unwrap_or(Value::String(permissions));
        json!({"permissions": parsed, "expires_at": expires_at})
    });
    Ok(json!({
        "device_id": row.get::<_, String>(0).map_err(ApiError::internal)?,
        "name": row.get::<_, String>(1).map_err(ApiError::internal)?,
        "owner_id": owner_id,
        "owner": row.get::<_, String>(3).map_err(ApiError::internal)?,
        "platform": row.get::<_, String>(4).map_err(ApiError::internal)?,
        "address": row.get::<_, String>(5).map_err(ApiError::internal)?,
        "fingerprint": row.get::<_, String>(6).map_err(ApiError::internal)?,
        "capabilities": row.get::<_, String>(7).map_err(ApiError::internal)?,
        "status": row.get::<_, String>(8).map_err(ApiError::internal)?,
        "last_seen": row.get::<_, i64>(9).map_err(ApiError::internal)?,
        "created_at": row.get::<_, i64>(10).map_err(ApiError::internal)?,
        "notes": row.get::<_, String>(11).map_err(ApiError::internal)?,
        "last_agent_seen": row.get::<_, i64>(12).map_err(ApiError::internal)?,
        "agent_instance": row.get::<_, String>(13).map_err(ApiError::internal)?,
        "presence": presence_state(now(), row.get::<_, i64>(12).map_err(ApiError::internal)?),
        "shared": shared,
        "grant": grant
    }))
}

async fn list_devices(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let ids: Vec<String> = if actor.role == "admin" {
        let mut stmt = conn
            .prepare("SELECT device_id FROM devices ORDER BY id")
            .map_err(|error| ApiError::internal(format!("prepare devices: {error}")))?;
        let rows = stmt
            .query_map([], |row| row.get(0))
            .map_err(|error| ApiError::internal(format!("list devices: {error}")))?
            .filter_map(Result::ok)
            .collect();
        drop(stmt);
        rows
    } else {
        let mut stmt = conn
            .prepare(
                "SELECT device_id FROM devices WHERE owner_id = ?1
                 UNION SELECT device_id FROM device_grants WHERE user_id = ?1
                   AND (expires_at = 0 OR expires_at > ?2)",
            )
            .map_err(|error| ApiError::internal(format!("prepare devices: {error}")))?;
        let rows = stmt
            .query_map(params![actor.id, now()], |row| row.get(0))
            .map_err(|error| ApiError::internal(format!("list devices: {error}")))?
            .filter_map(Result::ok)
            .collect();
        drop(stmt);
        rows
    };
    drop(conn);
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let mut devices = Vec::new();
    for id in ids {
        if let Ok(device) = device_json(&conn, &id, actor.id, &actor.role) {
            devices.push(device);
        }
    }
    Ok(Json(json!({"devices": devices})))
}

async fn register_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<DeviceRequest>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    let fingerprint = normalize_fingerprint(&request.fingerprint)?;
    if request.name.trim().is_empty() || request.name.len() > 120 {
        return Err(ApiError::bad("device name must be 1-120 characters"));
    }
    if request.platform.trim().is_empty() || request.platform.len() > 64 {
        return Err(ApiError::bad("platform must be 1-64 characters"));
    }
    if request.address.trim().is_empty() || request.address.len() > 255 {
        return Err(ApiError::bad("address must be 1-255 characters"));
    }
    let device_id = device_id_for(&fingerprint);
    let device_token = random_hex(32);
    let token_hash = sha256_hex(device_token.as_bytes());
    let capabilities = request
        .capabilities
        .map(|value| value.to_string())
        .unwrap_or_else(|| "{}".to_string());
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let existing: Option<(i64, i64)> = conn
        .query_row(
            "SELECT id, owner_id FROM devices WHERE device_id = ?1",
            params![device_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read device: {error}")))?;
    if let Some((id, owner_id)) = existing {
        if owner_id != actor.id && actor.role != "admin" {
            return Err(ApiError::conflict(
                "device is already registered to another account",
            ));
        }
        conn.execute(
            "UPDATE devices SET name = ?1, platform = ?2, address = ?3, fingerprint = ?4,
             capabilities = ?5, status = 'active', device_token_hash = ?6 WHERE id = ?7",
            params![
                request.name,
                request.platform,
                request.address,
                fingerprint,
                capabilities,
                token_hash,
                id
            ],
        )
        .map_err(|error| ApiError::internal(format!("update device: {error}")))?;
    } else {
        conn.execute(
            "INSERT INTO devices (device_id, name, owner_id, platform, address, fingerprint,
             capabilities, status, last_seen, created_at, device_token_hash)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'active', 0, ?8, ?9)",
            params![
                device_id,
                request.name,
                actor.id,
                request.platform,
                request.address,
                fingerprint,
                capabilities,
                now(),
                token_hash
            ],
        )
        .map_err(|error| ApiError::internal(format!("insert device: {error}")))?;
    }
    audit(
        &conn,
        Some(actor.id),
        "device.register",
        Some(&device_id),
        None,
    );
    drop(conn);
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let device = device_json(&conn, &device_id, actor.id, &actor.role)?;
    Ok(Json(
        json!({"device": device, "device_token": device_token}),
    ))
}

async fn revoke_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(device_id): AxumPath<String>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let owner: Option<i64> = conn
        .query_row(
            "SELECT owner_id FROM devices WHERE device_id = ?1",
            params![device_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read device owner: {error}")))?;
    let Some(owner_id) = owner else {
        return Err(ApiError::not_found("device not found"));
    };
    if owner_id != actor.id && actor.role != "admin" {
        return Err(ApiError::forbidden("only owner can revoke this device"));
    }
    conn.execute(
        "UPDATE devices SET status = 'revoked' WHERE device_id = ?1",
        params![device_id],
    )
    .map_err(|error| ApiError::internal(format!("revoke device: {error}")))?;
    conn.execute(
        "DELETE FROM device_grants WHERE device_id = ?1",
        params![device_id],
    )
    .map_err(|error| ApiError::internal(format!("revoke grants: {error}")))?;
    conn.execute(
        "UPDATE active_sessions SET revoked = 1
         WHERE device_id = ?1 AND ended_at IS NULL",
        params![device_id],
    )
    .map_err(|error| ApiError::internal(format!("revoke device sessions: {error}")))?;
    conn.execute(
        "UPDATE session_tickets SET revoked = 1, revoked_at = ?2
         WHERE device_id = ?1 AND revoked = 0",
        params![device_id, now()],
    )
    .map_err(|error| ApiError::internal(format!("revoke device tickets: {error}")))?;
    audit(
        &conn,
        Some(actor.id),
        "device.revoke",
        Some(&device_id),
        None,
    );
    Ok(Json(json!({"ok": true})))
}

async fn heartbeat(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(device_id): AxumPath<String>,
) -> Result<Json<Value>, ApiError> {
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let row: Option<(i64, String, String)> = conn
        .query_row(
            "SELECT owner_id, status, device_token_hash FROM devices WHERE device_id = ?1",
            params![device_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read device: {error}")))?;
    let Some((owner_id, device_status, token_hash)) = row else {
        return Err(ApiError::not_found("device is not registered"));
    };
    let bearer_user = bearer(&headers).and_then(|token| {
        let hash = sha256_hex(token.as_bytes());
        conn.query_row(
            "SELECT u.id, u.username, u.role FROM sessions s JOIN users u ON u.id=s.user_id
             WHERE s.token_hash=?1 AND s.revoked=0 AND s.expires_at>?2 AND u.status='active'",
            params![hash, now()],
            |row| {
                Ok(AuthUser {
                    id: row.get(0)?,
                    username: row.get(1)?,
                    role: row.get(2)?,
                })
            },
        )
        .optional()
        .ok()
        .flatten()
    });
    let device_token_ok = headers
        .get("x-device-token")
        .and_then(|value| value.to_str().ok())
        .map(|value| constant_time_eq(&sha256_hex(value.as_bytes()), &token_hash))
        .unwrap_or(false);
    let bearer_ok = bearer_user
        .as_ref()
        .map(|user| user.id == owner_id || user.role == "admin")
        .unwrap_or(false);
    if !device_token_ok && !bearer_ok {
        return Err(ApiError::unauthorized(
            "device token or owner session required",
        ));
    }
    let owner_status: Option<String> = conn
        .query_row(
            "SELECT status FROM users WHERE id = ?1",
            params![owner_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read owner status: {error}")))?;
    let owner_active = owner_status.as_deref() == Some("active");
    let active = device_status == "active" && owner_active;
    let now_v = now();
    if !active {
        conn.execute(
            "UPDATE active_sessions SET revoked = 1
             WHERE device_id = ?1 AND ended_at IS NULL",
            params![device_id],
        )
        .map_err(|error| ApiError::internal(format!("revoke disabled device: {error}")))?;
        conn.execute(
            "UPDATE session_tickets SET revoked = 1, revoked_at = ?1
             WHERE device_id = ?2 AND revoked = 0",
            params![now_v, device_id],
        )
        .map_err(|error| ApiError::internal(format!("revoke pending tickets: {error}")))?;
    }
    // Only a request authenticated as the device agent is presence evidence.
    // An owner/admin browser session cannot make a Host look online.
    let agent_instance = headers
        .get("x-host-instance")
        .and_then(|value| value.to_str().ok())
        .unwrap_or("")
        .trim()
        .to_string();
    let last_agent_seen: i64 = if device_token_ok && active {
        if agent_instance.len() > 64 {
            return Err(ApiError::bad("host instance id is too long"));
        }
        conn.execute(
            "UPDATE devices SET last_seen = ?1, last_agent_seen = ?1, agent_instance = ?2
             WHERE device_id = ?3",
            params![now_v, agent_instance, device_id],
        )
        .map_err(|error| ApiError::internal(format!("update heartbeat: {error}")))?;
        conn.execute(
            "UPDATE active_sessions SET last_seen = ?1
             WHERE device_id = ?2 AND ended_at IS NULL",
            params![now_v, device_id],
        )
        .map_err(|error| ApiError::internal(format!("refresh session lease: {error}")))?;
        now_v
    } else {
        conn.query_row(
            "SELECT last_agent_seen FROM devices WHERE device_id = ?1",
            params![device_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read agent presence: {error}")))?
        .unwrap_or(0)
    };
    conn.execute(
        "UPDATE active_sessions SET ended_at = ?1, end_reason = 'lease_expired'
         WHERE device_id = ?2 AND ended_at IS NULL AND last_seen < ?3",
        params![now_v, device_id, now_v - SESSION_LEASE_SECS],
    )
    .map_err(|error| ApiError::internal(format!("expire stale sessions: {error}")))?;
    let revoked_sessions: Vec<String> = {
        let mut stmt = conn
            .prepare(
                "SELECT session_id FROM active_sessions
                 WHERE device_id = ?1 AND revoked = 1 AND ended_at IS NULL",
            )
            .map_err(|error| ApiError::internal(format!("prepare revocations: {error}")))?;
        let rows = stmt
            .query_map(params![device_id], |row| row.get(0))
            .map_err(|error| ApiError::internal(format!("read revocations: {error}")))?
            .filter_map(Result::ok)
            .collect();
        rows
    };
    let revoked_tickets: Vec<String> = {
        let mut stmt = conn
            .prepare(
                "SELECT jti FROM session_tickets
                 WHERE device_id = ?1 AND revoked = 1 AND expires_at > ?2
                 ORDER BY issued_at DESC LIMIT 100",
            )
            .map_err(|error| ApiError::internal(format!("prepare ticket revocations: {error}")))?;
        let rows = stmt
            .query_map(params![device_id, now_v], |row| row.get(0))
            .map_err(|error| ApiError::internal(format!("read ticket revocations: {error}")))?
            .filter_map(Result::ok)
            .collect();
        rows
    };
    let presence = presence_state(now_v, last_agent_seen);
    Ok(Json(json!({
        "ok": true,
        "last_seen": last_agent_seen,
        "last_agent_seen": last_agent_seen,
        "owner_active": active,
        "device_status": device_status,
        "presence": presence,
        "presence_threshold_secs": PRESENCE_ONLINE_SECS,
        "agent_instance": agent_instance,
        "revoked_sessions": revoked_sessions,
        "revoked_tickets": revoked_tickets,
        "server_now": now_v,
    })))
}

fn presence_state(now_v: i64, last_agent_seen: i64) -> &'static str {
    if last_agent_seen <= 0 {
        "unknown"
    } else if now_v.saturating_sub(last_agent_seen) <= PRESENCE_ONLINE_SECS {
        "online"
    } else {
        "offline"
    }
}

async fn connect_info(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(device_id): AxumPath<String>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let device = device_json(&conn, &device_id, actor.id, &actor.role)?;
    if device["status"] != "active" {
        return Err(ApiError::conflict("device is not active"));
    }
    audit(
        &conn,
        Some(actor.id),
        "device.connect_info",
        Some(&device_id),
        None,
    );
    let permissions = if device["shared"] == true {
        device["grant"]["permissions"].clone()
    } else {
        json!(["view", "control"])
    };
    Ok(Json(json!({
        "device_id": device["device_id"],
        "name": device["name"],
        "address": device["address"],
        "fingerprint": device["fingerprint"],
        "owner": device["owner"],
        "permissions": permissions
    })))
}

async fn create_pairing_code(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(device_id): AxumPath<String>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let owner: Option<i64> = conn
        .query_row(
            "SELECT owner_id FROM devices WHERE device_id=?1 AND status='active'",
            params![device_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read device: {error}")))?;
    let Some(owner_id) = owner else {
        return Err(ApiError::not_found("active device not found"));
    };
    if owner_id != actor.id && actor.role != "admin" {
        return Err(ApiError::forbidden("only owner can create a pairing code"));
    }
    let code = random_code(8);
    let expires = now() + PAIRING_TTL_SECS;
    conn.execute(
        "INSERT INTO pairing_codes (code, device_id, created_by, expires_at, used) VALUES (?1, ?2, ?3, ?4, 0)",
        params![code, device_id, actor.id, expires],
    )
    .map_err(|error| ApiError::internal(format!("create pairing code: {error}")))?;
    audit(
        &conn,
        Some(actor.id),
        "pairing.create",
        Some(&device_id),
        None,
    );
    Ok(Json(
        json!({"code": code, "expires_at": expires, "ttl_seconds": PAIRING_TTL_SECS}),
    ))
}

async fn claim_pairing(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<ClaimRequest>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let row: Option<(String, i64, i64, i64)> = conn
        .query_row(
            "SELECT device_id, created_by, expires_at, used FROM pairing_codes WHERE code=?1",
            params![request.code.trim().to_uppercase()],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read pairing code: {error}")))?;
    let Some((device_id, created_by, expires_at, used)) = row else {
        return Err(ApiError::not_found("pairing code is invalid"));
    };
    if used != 0 || expires_at <= now() {
        return Err(ApiError::conflict(
            "pairing code is expired or already used",
        ));
    }
    if created_by == actor.id {
        return Err(ApiError::conflict(
            "owner cannot claim their own pairing code",
        ));
    }
    let status: Option<String> = conn
        .query_row(
            "SELECT status FROM devices WHERE device_id=?1",
            params![device_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read device status: {error}")))?;
    if status.as_deref() != Some("active") {
        return Err(ApiError::conflict("device is not active"));
    }
    let expires = now() + GRANT_TTL_SECS;
    let permissions = json!(["view", "control"]).to_string();
    conn.execute(
        "INSERT INTO device_grants (device_id, user_id, permissions, expires_at, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(device_id, user_id) DO UPDATE SET permissions=excluded.permissions, expires_at=excluded.expires_at",
        params![device_id, actor.id, permissions, expires, now()],
    )
    .map_err(|error| ApiError::internal(format!("grant device access: {error}")))?;
    conn.execute(
        "UPDATE pairing_codes SET used=1 WHERE code=?1",
        params![request.code.trim().to_uppercase()],
    )
    .map_err(|error| ApiError::internal(format!("consume pairing code: {error}")))?;
    let device = device_json(&conn, &device_id, actor.id, &actor.role)?;
    audit(
        &conn,
        Some(actor.id),
        "pairing.claim",
        Some(&device_id),
        None,
    );
    Ok(Json(
        json!({"ok": true, "device": device, "grant_expires_at": expires}),
    ))
}

async fn audit_list(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    require_admin(&actor)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let mut stmt = conn
        .prepare("SELECT id, actor_id, action, target, detail, created_at FROM audit ORDER BY id DESC LIMIT 200")
        .map_err(|error| ApiError::internal(format!("prepare audit: {error}")))?;
    let entries = stmt
        .query_map([], |row| {
            Ok(json!({
                "id": row.get::<_, i64>(0)?,
                "actor_id": row.get::<_, Option<i64>>(1)?,
                "action": row.get::<_, String>(2)?,
                "target": row.get::<_, Option<String>>(3)?,
                "detail": row.get::<_, Option<String>>(4)?,
                "created_at": row.get::<_, i64>(5)?
            }))
        })
        .map_err(|error| ApiError::internal(format!("list audit: {error}")))?
        .filter_map(Result::ok)
        .collect::<Vec<_>>();
    Ok(Json(json!({"audit": entries})))
}

async fn device_grants(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(device_id): AxumPath<String>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let owner: Option<i64> = conn
        .query_row(
            "SELECT owner_id FROM devices WHERE device_id=?1",
            params![device_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read device owner: {error}")))?;
    let Some(owner_id) = owner else {
        return Err(ApiError::not_found("device not found"));
    };
    if owner_id != actor.id && actor.role != "admin" {
        return Err(ApiError::forbidden("only owner can inspect grants"));
    }
    let mut stmt = conn
        .prepare("SELECT g.user_id, u.username, g.permissions, g.expires_at FROM device_grants g JOIN users u ON u.id=g.user_id WHERE g.device_id=?1")
        .map_err(|error| ApiError::internal(format!("prepare grants: {error}")))?;
    let grants = stmt
        .query_map(params![device_id], |row| {
            Ok(json!({
                "user_id": row.get::<_, i64>(0)?,
                "username": row.get::<_, String>(1)?,
                "permissions": row.get::<_, String>(2)?,
                "expires_at": row.get::<_, i64>(3)?
            }))
        })
        .map_err(|error| ApiError::internal(format!("list grants: {error}")))?
        .filter_map(Result::ok)
        .collect::<Vec<_>>();
    Ok(Json(json!({"grants": grants})))
}

async fn revoke_grant(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath((device_id, user_id)): AxumPath<(String, i64)>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let owner: Option<i64> = conn
        .query_row(
            "SELECT owner_id FROM devices WHERE device_id=?1",
            params![device_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read device owner: {error}")))?;
    let Some(owner_id) = owner else {
        return Err(ApiError::not_found("device not found"));
    };
    if owner_id != actor.id && actor.role != "admin" {
        return Err(ApiError::forbidden("only owner can revoke a share"));
    }
    let timestamp = now();
    let removed = conn
        .execute(
            "DELETE FROM device_grants WHERE device_id = ?1 AND user_id = ?2",
            params![device_id, user_id],
        )
        .map_err(|error| ApiError::internal(format!("revoke grant: {error}")))?;
    if removed == 0 {
        return Err(ApiError::not_found("grant not found"));
    }
    conn.execute(
        "UPDATE active_sessions SET revoked = 1
         WHERE device_id = ?1 AND user_id = ?2 AND ended_at IS NULL",
        params![device_id, user_id],
    )
    .map_err(|error| ApiError::internal(format!("revoke grant sessions: {error}")))?;
    conn.execute(
        "UPDATE session_tickets SET revoked = 1, revoked_at = ?3
         WHERE device_id = ?1 AND user_id = ?2 AND revoked = 0",
        params![device_id, user_id, timestamp],
    )
    .map_err(|error| ApiError::internal(format!("revoke grant tickets: {error}")))?;
    audit(
        &conn,
        Some(actor.id),
        "grant.revoke",
        Some(&device_id),
        Some(&user_id.to_string()),
    );
    Ok(Json(json!({"ok": true, "sessions_revoked": true})))
}

#[derive(Debug, Default, Deserialize)]
struct DeviceQuery {
    q: Option<String>,
    status: Option<String>,
    presence: Option<String>,
    limit: Option<u32>,
    offset: Option<u32>,
}

#[derive(Debug, Default, Deserialize)]
struct SessionQuery {
    device_id: Option<String>,
    state: Option<String>,
    limit: Option<u32>,
    offset: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct DevicePatch {
    name: Option<String>,
    notes: Option<String>,
}

fn clamp_limit(value: Option<u32>, default: u32) -> u32 {
    value.unwrap_or(default).clamp(1, 100)
}

async fn admin_overview(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    require_admin(&actor)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let now_v = now();
    let count = |sql: &str, at: i64| -> Result<i64, ApiError> {
        conn.query_row(sql, params![at], |row| row.get(0))
            .map_err(|error| ApiError::internal(format!("overview count: {error}")))
    };
    let devices: i64 = conn
        .query_row("SELECT COUNT(*) FROM devices", [], |row| row.get(0))
        .map_err(|error| ApiError::internal(format!("count devices: {error}")))?;
    let registered: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM devices WHERE status = 'active'",
            [],
            |row| row.get(0),
        )
        .map_err(|error| ApiError::internal(format!("count active devices: {error}")))?;
    let online: i64 = count(
        "SELECT COUNT(*) FROM devices WHERE last_agent_seen >= ?1",
        now_v - PRESENCE_ONLINE_SECS,
    )?;
    let users: i64 = conn
        .query_row("SELECT COUNT(*) FROM users", [], |row| row.get(0))
        .map_err(|error| ApiError::internal(format!("count users: {error}")))?;
    let active_sessions: i64 = count(
        "SELECT COUNT(*) FROM active_sessions
         WHERE ended_at IS NULL AND revoked = 0 AND last_seen >= ?1",
        now_v - SESSION_ACTIVE_SECS,
    )?;
    let revoking: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM active_sessions WHERE ended_at IS NULL AND revoked = 1",
            [],
            |row| row.get(0),
        )
        .map_err(|error| ApiError::internal(format!("count revoking: {error}")))?;
    let stale: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM active_sessions
             WHERE ended_at IS NULL AND last_seen < ?1",
            params![now_v - SESSION_ACTIVE_SECS],
            |row| row.get(0),
        )
        .map_err(|error| ApiError::internal(format!("count stale: {error}")))?;
    let mut path_stmt = conn
        .prepare(
            "SELECT path, COUNT(*) FROM active_sessions
             WHERE ended_at IS NULL GROUP BY path ORDER BY path",
        )
        .map_err(|error| ApiError::internal(format!("prepare path stats: {error}")))?;
    let path_counts = path_stmt
        .query_map([], |row| {
            Ok(json!({
                "path": row.get::<_, String>(0)?,
                "sessions": row.get::<_, i64>(1)?,
            }))
        })
        .map_err(|error| ApiError::internal(format!("path stats: {error}")))?
        .filter_map(Result::ok)
        .collect::<Vec<_>>();
    Ok(Json(json!({
        "server_now": now_v,
        "started_at": state.started_at,
        "uptime_secs": now_v.saturating_sub(state.started_at),
        "devices": devices,
        "registered_devices": registered,
        "online_devices": online,
        "users": users,
        "active_sessions": active_sessions,
        "revoking_sessions": revoking,
        "stale_sessions": stale,
        "path_counts": path_counts,
        "presence_threshold_secs": PRESENCE_ONLINE_SECS,
        "session_active_secs": SESSION_ACTIVE_SECS,
        "session_lease_secs": SESSION_LEASE_SECS,
        "p2p_enabled": false,
        "relay_enabled": false,
        "network_note": "P2P/ICE/TURN 未实现；仅 TCP/TLS 直连",
    })))
}

async fn admin_devices(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<DeviceQuery>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    require_admin(&actor)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let now_v = now();
    let limit = clamp_limit(query.limit, 25);
    let offset = query.offset.unwrap_or(0).min(1_000_000);
    let search = query.q.unwrap_or_default().trim().to_string();
    if search.len() > 120 {
        return Err(ApiError::bad("search text is too long"));
    }
    let pattern = format!("%{search}%");
    let status = query.status.unwrap_or_default();
    if !status.is_empty() && status != "active" && status != "revoked" {
        return Err(ApiError::bad("status must be active or revoked"));
    }
    let presence = query.presence.unwrap_or_default();
    if !presence.is_empty() && !matches!(presence.as_str(), "online" | "offline" | "unknown") {
        return Err(ApiError::bad("presence must be online, offline or unknown"));
    }
    let online_cutoff = now_v - PRESENCE_ONLINE_SECS;
    let where_sql = "WHERE (?1 = '' OR d.name LIKE ?2 OR d.device_id LIKE ?2)
        AND (?3 = '' OR d.status = ?3)
        AND (?4 = '' OR
             (?4 = 'online' AND d.last_agent_seen >= ?5) OR
             (?4 = 'offline' AND d.last_agent_seen > 0 AND d.last_agent_seen < ?5) OR
             (?4 = 'unknown' AND d.last_agent_seen = 0))";
    let total: i64 = conn
        .query_row(
            &format!("SELECT COUNT(*) FROM devices d {where_sql}"),
            params![search, pattern, status, presence, online_cutoff],
            |row| row.get(0),
        )
        .map_err(|error| ApiError::internal(format!("count filtered devices: {error}")))?;
    let mut stmt = conn
        .prepare(&format!(
            "SELECT d.device_id, d.name, d.owner_id, u.username, d.platform, d.address,
                    d.fingerprint, d.status, d.last_seen, d.last_agent_seen, d.agent_instance,
                    d.notes, d.created_at,
                    (SELECT COUNT(*) FROM active_sessions s
                     WHERE s.device_id = d.device_id AND s.ended_at IS NULL),
                    (SELECT s.path FROM active_sessions s
                     WHERE s.device_id = d.device_id AND s.ended_at IS NULL
                     ORDER BY s.started_at DESC LIMIT 1)
             FROM devices d JOIN users u ON u.id = d.owner_id
             {where_sql}
             ORDER BY d.name COLLATE NOCASE, d.device_id
             LIMIT ?6 OFFSET ?7"
        ))
        .map_err(|error| ApiError::internal(format!("prepare admin devices: {error}")))?;
    let devices = stmt
        .query_map(
            params![
                search,
                pattern,
                status,
                presence,
                online_cutoff,
                limit,
                offset
            ],
            |row| {
                let last_agent_seen: i64 = row.get(9)?;
                Ok(json!({
                    "device_id": row.get::<_, String>(0)?,
                    "name": row.get::<_, String>(1)?,
                    "owner_id": row.get::<_, i64>(2)?,
                    "owner": row.get::<_, String>(3)?,
                    "platform": row.get::<_, String>(4)?,
                    "address": row.get::<_, String>(5)?,
                    "fingerprint": row.get::<_, String>(6)?,
                    "status": row.get::<_, String>(7)?,
                    "last_seen": row.get::<_, i64>(8)?,
                    "last_agent_seen": last_agent_seen,
                    "agent_instance": row.get::<_, String>(10)?,
                    "notes": row.get::<_, String>(11)?,
                    "created_at": row.get::<_, i64>(12)?,
                    "session_count": row.get::<_, i64>(13)?,
                    "path": row.get::<_, Option<String>>(14)?,
                    "presence": presence_state(now_v, last_agent_seen),
                }))
            },
        )
        .map_err(|error| ApiError::internal(format!("list admin devices: {error}")))?
        .filter_map(Result::ok)
        .collect::<Vec<_>>();
    Ok(Json(json!({
        "devices": devices,
        "total": total,
        "limit": limit,
        "offset": offset,
        "server_now": now_v,
        "presence_threshold_secs": PRESENCE_ONLINE_SECS,
    })))
}

async fn admin_sessions(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<SessionQuery>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    require_admin(&actor)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let now_v = now();
    let device_filter = query.device_id.unwrap_or_default();
    let mut stmt = conn
        .prepare(
            "SELECT s.session_id, s.device_id, d.name, s.user_id, u.username, s.permissions,
                    s.ticket_permissions, s.started_at, s.last_seen, s.ended_at, s.revoked,
                    s.host_instance, s.request_input, s.input_allowed, s.path, s.end_reason
             FROM active_sessions s
             LEFT JOIN devices d ON d.device_id = s.device_id
             LEFT JOIN users u ON u.id = s.user_id
             WHERE (?1 = '' OR s.device_id = ?1)
             ORDER BY s.started_at DESC LIMIT 500",
        )
        .map_err(|error| ApiError::internal(format!("prepare admin sessions: {error}")))?;
    let mut rows = stmt
        .query_map(params![device_filter], |row| {
            let last_seen: i64 = row.get(8)?;
            let ended_at: Option<i64> = row.get(9)?;
            let revoked = row.get::<_, i64>(10)? == 1;
            Ok(json!({
                "session_id": row.get::<_, String>(0)?,
                "device_id": row.get::<_, String>(1)?,
                "device_name": row.get::<_, Option<String>>(2)?,
                "user_id": row.get::<_, i64>(3)?,
                "user": row.get::<_, Option<String>>(4)?,
                "permissions": row.get::<_, i64>(5)?,
                "permission_names": yl_proto::permission_summary(row.get::<_, i64>(5)? as u32),
                "ticket_permissions": row.get::<_, i64>(6)?,
                "started_at": row.get::<_, i64>(7)?,
                "last_seen": last_seen,
                "ended_at": ended_at,
                "revoked": revoked,
                "state": session_state(now_v, last_seen, ended_at, revoked),
                "host_instance": row.get::<_, String>(11)?,
                "request_input": row.get::<_, i64>(12)? == 1,
                "input_allowed": row.get::<_, i64>(13)? == 1,
                "path": row.get::<_, String>(14)?,
                "end_reason": row.get::<_, Option<String>>(15)?,
            }))
        })
        .map_err(|error| ApiError::internal(format!("list admin sessions: {error}")))?
        .filter_map(Result::ok)
        .collect::<Vec<_>>();
    if let Some(filter) = query.state.filter(|value| !value.is_empty()) {
        rows.retain(|value| value["state"].as_str() == Some(filter.as_str()));
    }
    let total = rows.len() as i64;
    let limit = clamp_limit(query.limit, 50) as usize;
    let offset = query.offset.unwrap_or(0) as usize;
    let page = rows
        .into_iter()
        .skip(offset)
        .take(limit)
        .collect::<Vec<_>>();
    Ok(Json(json!({
        "sessions": page,
        "total": total,
        "limit": limit,
        "offset": offset,
        "server_now": now_v,
    })))
}

async fn device_detail(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(device_id): AxumPath<String>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let device = device_json(&conn, &device_id, actor.id, &actor.role)?;
    let mut stmt = conn
        .prepare(
            "SELECT s.session_id, s.user_id, u.username, s.permissions, s.started_at,
                    s.last_seen, s.revoked, s.ended_at, s.path, s.host_instance
             FROM active_sessions s LEFT JOIN users u ON u.id = s.user_id
             WHERE s.device_id = ?1 AND s.ended_at IS NULL ORDER BY s.started_at DESC",
        )
        .map_err(|error| ApiError::internal(format!("prepare device sessions: {error}")))?;
    let now_v = now();
    let sessions = stmt
        .query_map(params![device_id], |row| {
            let last_seen: i64 = row.get(5)?;
            let revoked = row.get::<_, i64>(6)? == 1;
            let ended_at: Option<i64> = row.get(7)?;
            Ok(json!({
                "session_id": row.get::<_, String>(0)?,
                "user_id": row.get::<_, i64>(1)?,
                "user": row.get::<_, Option<String>>(2)?,
                "permissions": row.get::<_, i64>(3)?,
                "permission_names": yl_proto::permission_summary(row.get::<_, i64>(3)? as u32),
                "started_at": row.get::<_, i64>(4)?,
                "last_seen": last_seen,
                "revoked": revoked,
                "ended_at": ended_at,
                "state": session_state(now_v, last_seen, ended_at, revoked),
                "path": row.get::<_, String>(8)?,
                "host_instance": row.get::<_, String>(9)?,
            }))
        })
        .map_err(|error| ApiError::internal(format!("list device sessions: {error}")))?
        .filter_map(Result::ok)
        .collect::<Vec<_>>();
    Ok(Json(
        json!({"device": device, "sessions": sessions, "server_now": now_v}),
    ))
}

async fn patch_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(device_id): AxumPath<String>,
    Json(request): Json<DevicePatch>,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let owner: Option<i64> = conn
        .query_row(
            "SELECT owner_id FROM devices WHERE device_id = ?1",
            params![device_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read device owner: {error}")))?;
    let Some(owner_id) = owner else {
        return Err(ApiError::not_found("device not found"));
    };
    if owner_id != actor.id && actor.role != "admin" {
        return Err(ApiError::forbidden("only owner can edit this device"));
    }
    if let Some(name) = request.name.as_deref() {
        let name = name.trim();
        if name.is_empty() || name.len() > 120 {
            return Err(ApiError::bad("device name must be 1-120 characters"));
        }
        conn.execute(
            "UPDATE devices SET name = ?1 WHERE device_id = ?2",
            params![name, device_id],
        )
        .map_err(|error| ApiError::internal(format!("rename device: {error}")))?;
    }
    if let Some(notes) = request.notes.as_deref() {
        if notes.len() > 2000 {
            return Err(ApiError::bad("notes are limited to 2000 characters"));
        }
        conn.execute(
            "UPDATE devices SET notes = ?1 WHERE device_id = ?2",
            params![notes, device_id],
        )
        .map_err(|error| ApiError::internal(format!("update notes: {error}")))?;
    }
    audit(
        &conn,
        Some(actor.id),
        "device.patch",
        Some(&device_id),
        None,
    );
    let device = device_json(&conn, &device_id, actor.id, &actor.role)?;
    Ok(Json(json!({"device": device})))
}

async fn network_capabilities(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let _actor = authenticate(&state, &headers)?;
    Ok(Json(json!({
        "transports": ["direct_tcp_tls"],
        "session_modes": ["tiles", "flow", "quality"],
        "quality_streaming": {"supported": true, "requires": "host_v3_dedicated_sunshine", "embedded": false},
        "p2p": false,
        "ice": false,
        "stun": false,
        "turn": false,
        "reason": "P2P/ICE/TURN 尚未实现；当前只使用 TCP/TLS 直连",
        "path_policy": ["direct_tcp_tls"],
    })))
}

async fn admin_network_status(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let actor = authenticate(&state, &headers)?;
    require_admin(&actor)?;
    Ok(Json(json!({
        "p2p_enabled": false,
        "turn_configured": false,
        "stun_configured": false,
        "relay_configured": false,
        "active_transports": ["direct_tcp_tls"],
        "reason": "P2P/ICE/TURN 与中继尚未实现；不能伪造候选或中继状态",
        "config_source": "none",
        "server_now": now(),
    })))
}

fn app_router(state: AppState) -> Router {
    Router::new()
        .route("/", get(admin_page))
        .route("/admin", get(admin_page))
        .route("/health", get(health))
        .route("/api/v1/server/info", get(server_info))
        .route("/api/v1/server/ticket-key", get(ticket_keys))
        .route("/api/v1/admin/overview", get(admin_overview))
        .route("/api/v1/admin/devices", get(admin_devices))
        .route("/api/v1/admin/sessions", get(admin_sessions))
        .route("/api/v1/admin/network/status", get(admin_network_status))
        .route("/api/v1/network/capabilities", get(network_capabilities))
        .route("/api/v1/setup", post(setup))
        .route("/api/v1/auth/login", post(login))
        .route("/api/v1/auth/logout", post(logout))
        .route("/api/v1/auth/refresh", post(refresh))
        .route("/api/v1/auth/password", post(change_password))
        .route("/api/v1/auth/register", post(register_with_invite))
        .route("/api/v1/me", get(me))
        .route("/api/v1/invites", post(create_invite))
        .route("/api/v1/users", get(list_users))
        .route("/api/v1/users/{id}/status", post(set_user_status))
        .route("/api/v1/devices", get(list_devices).post(register_device))
        .route(
            "/api/v1/devices/{id}",
            get(device_detail).patch(patch_device),
        )
        .route("/api/v1/devices/{id}/revoke", post(revoke_device))
        .route("/api/v1/devices/{id}/heartbeat", post(heartbeat))
        .route("/api/v1/devices/{id}/connect-info", get(connect_info))
        .route(
            "/api/v1/devices/{id}/session-ticket",
            post(issue_session_ticket),
        )
        .route(
            "/api/v1/devices/{id}/sessions",
            get(list_sessions).post(report_session_start),
        )
        .route(
            "/api/v1/devices/{id}/sessions/revoke",
            post(revoke_sessions),
        )
        .route(
            "/api/v1/devices/{id}/sessions/{session_id}/end",
            post(report_session_end),
        )
        .route(
            "/api/v1/devices/{id}/session-tickets/{jti}",
            get(ticket_status),
        )
        .route(
            "/api/v1/devices/{id}/pairing-code",
            post(create_pairing_code),
        )
        .route("/api/v1/devices/{id}/grants", get(device_grants))
        .route(
            "/api/v1/devices/{id}/grants/{user_id}/revoke",
            post(revoke_grant),
        )
        .route("/api/v1/pairing/claim", post(claim_pairing))
        .route("/api/v1/audit", get(audit_list))
        .with_state(state)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("yl_server=info,info")),
        )
        .with_target(false)
        .compact()
        .init();

    let bind = env::var("YUANLIAN_BIND").unwrap_or_else(|_| "127.0.0.1:18080".to_string());
    let db_path = env::var("YUANLIAN_DB").unwrap_or_else(|_| "yuanlian.db".to_string());
    let conn = open_db(Path::new(&db_path))?;
    let ticket_key = ensure_ticket_key(&conn)?;
    info!(ticket_kid = %ticket_key.kid, "session ticket signing key ready");
    let state = AppState {
        db: Arc::new(Mutex::new(conn)),
        started_at: now(),
        login_guard: Arc::new(Mutex::new(HashMap::new())),
        ticket_key: Arc::new(ticket_key),
    };
    let _started_at = state.started_at;
    let cleanup_state = state.clone();
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(std::time::Duration::from_secs(5));
        loop {
            ticker.tick().await;
            let Ok(conn) = cleanup_state.db.lock() else {
                continue;
            };
            let timestamp = now();
            let _ = conn.execute(
                "UPDATE active_sessions SET ended_at = ?1, end_reason = 'lease_expired'
                 WHERE ended_at IS NULL AND last_seen < ?2",
                params![timestamp, timestamp - SESSION_LEASE_SECS],
            );
        }
    });
    let app = app_router(state);
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    info!(%bind, %db_path, version = env!("CARGO_PKG_VERSION"), "control server listening");
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_modes_are_allowed_and_unknown_modes_are_rejected() {
        for mode in ["tiles", "flow", "quality"] {
            assert!(require_supported_session_mode(mode).is_ok());
        }
        for mode in ["moonlight", "file_only", "", "TILES"] {
            let error = require_supported_session_mode(mode).unwrap_err();
            assert_eq!(error.status, StatusCode::CONFLICT);
            assert_eq!(error.code, "unsupported_mode");
        }
    }

    #[test]
    fn legacy_ticket_requests_remain_tiles_and_engine_alias_is_checked() {
        let legacy: TicketRequest =
            serde_json::from_value(json!({"nonce": "ab".repeat(32)})).unwrap();
        assert_eq!(legacy.mode, "tiles");
        let quality: TicketRequest =
            serde_json::from_value(json!({"nonce": "ab".repeat(32), "engine": "quality"})).unwrap();
        assert!(require_supported_session_mode(&quality.mode).is_ok());
    }

    #[test]
    fn password_hash_roundtrip() {
        let hash = hash_password("correct horse battery staple").unwrap();
        assert!(verify_password(&hash, "correct horse battery staple"));
        assert!(!verify_password(&hash, "wrong password"));
    }

    #[test]
    fn fingerprint_normalization() {
        let value = format!("{}:{}", "AA".repeat(16), "BB".repeat(16));
        let normalized = normalize_fingerprint(&value).unwrap();
        assert_eq!(normalized.len(), 64);
        assert!(normalized.starts_with("aaaa"));
        assert!(normalize_fingerprint("abc").is_err());
    }

    #[test]
    fn device_ids_are_stable_and_prefixed() {
        let fingerprint = "aa".repeat(32);
        let a = device_id_for(&fingerprint);
        let b = device_id_for(&fingerprint);
        assert_eq!(a, b);
        assert!(a.starts_with("yl-"));
        assert_eq!(a, yl_proto::device_id_from_fingerprint(&fingerprint));
    }

    #[test]
    fn permissions_are_parsed_from_grants() {
        let bits = permission_bits(&json!([
            "view",
            "control",
            "file_read",
            "file_write",
            "file_delete",
            "unknown"
        ]));
        assert_eq!(bits, PERMISSION_ALL);
        assert_eq!(permission_bits(&json!(["view"])), PERMISSION_VIEW);
        assert_eq!(permission_bits(&json!([])), 0);
    }

    #[test]
    fn constant_time_comparison_is_exact() {
        assert!(constant_time_eq("abcdef", "abcdef"));
        assert!(!constant_time_eq("abcdef", "abcdeg"));
        assert!(!constant_time_eq("abcdef", "abcde"));
    }

    #[test]
    fn session_state_distinguishes_active_unknown_stale_end() {
        let now = 1_000;
        assert_eq!(session_state(now, now - 1, None, false), "active");
        assert_eq!(session_state(now, now - 20, None, false), "unknown");
        assert_eq!(session_state(now, now - 31, None, false), "stale");
        assert_eq!(session_state(now, now - 31, Some(now), false), "ended");
        assert_eq!(session_state(now, now - 1, None, true), "revoking");
    }

    #[test]
    fn presence_is_agent_evidence_not_registration_status() {
        assert_eq!(presence_state(1_000, 0), "unknown");
        assert_eq!(presence_state(1_000, 996), "online");
        assert_eq!(presence_state(1_000, 900), "offline");
    }

    #[test]
    fn limits_and_session_ids_are_bounded() {
        assert_eq!(clamp_limit(None, 25), 25);
        assert_eq!(clamp_limit(Some(0), 25), 1);
        assert_eq!(clamp_limit(Some(10_000), 25), 100);
        assert!(valid_session_id("abc-123_X"));
        assert!(!valid_session_id(""));
        assert!(!valid_session_id("bad id"));
        assert!(!valid_session_id(&"a".repeat(129)));
    }

    #[test]
    fn schema_migration_creates_ticket_and_presence_columns() {
        let conn = open_db(Path::new(":memory:")).unwrap();
        let columns = |table: &str| -> Vec<String> {
            let mut statement = conn
                .prepare(&format!("PRAGMA table_info({table})"))
                .unwrap();
            statement
                .query_map([], |row| row.get::<_, String>(1))
                .unwrap()
                .filter_map(Result::ok)
                .collect()
        };
        let devices = columns("devices");
        for column in ["notes", "last_agent_seen", "agent_instance"] {
            assert!(devices.iter().any(|value| value == column), "{column}");
        }
        let sessions = columns("active_sessions");
        for column in [
            "ticket_permissions",
            "host_instance",
            "request_input",
            "input_allowed",
            "path",
            "end_reason",
        ] {
            assert!(sessions.iter().any(|value| value == column), "{column}");
        }
        let tickets = columns("session_tickets");
        for column in [
            "jti",
            "device_id",
            "user_id",
            "permissions",
            "revoked",
            "started_at",
        ] {
            assert!(tickets.iter().any(|value| value == column), "{column}");
        }
    }

    #[test]
    fn ticket_key_persists_and_signs_valid_claims() {
        let conn = open_db(Path::new(":memory:")).unwrap();
        let key = ensure_ticket_key(&conn).unwrap();
        let again = ensure_ticket_key(&conn).unwrap();
        assert_eq!(key.kid, again.kid);
        let nonce = "12".repeat(32);
        let now = now();
        let claims = SessionClaims {
            v: TICKET_VERSION,
            kid: key.kid.clone(),
            aud: "yl-test".into(),
            sub: 3,
            user: "alice".into(),
            jti: "session-test".into(),
            purpose: TICKET_PURPOSE.into(),
            mode: "tiles".into(),
            nonce_sha256: nonce_sha256(&nonce),
            permissions: PERMISSION_VIEW | PERMISSION_CONTROL,
            iat: now,
            exp: now + 60,
        };
        let token = sign_ticket(&key.private_pkcs8, &claims).unwrap();
        let public = ticket_key_from_pkcs8(&key.private_pkcs8).unwrap();
        let parsed =
            yl_proto::auth::verify_session_ticket(&token, &[public], "yl-test", &nonce, now + 1)
                .unwrap();
        assert_eq!(parsed, claims);
    }
}
