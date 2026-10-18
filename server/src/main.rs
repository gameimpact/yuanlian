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
use axum::extract::{ConnectInfo, Path as AxumPath, State};
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

const SESSION_TTL_SECS: i64 = 86_400;
const PAIRING_TTL_SECS: i64 = 600;
const GRANT_TTL_SECS: i64 = 7 * 86_400;
const ADMIN_HTML: &str = include_str!("../admin/index.html");

#[derive(Clone)]
struct AppState {
    db: Arc<Mutex<Connection>>,
    started_at: i64,
    login_guard: Arc<Mutex<HashMap<String, (u32, i64)>>>,
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
            device_token_hash TEXT NOT NULL
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
        "#,
    )
    .map_err(|error| ApiError::internal(format!("initialize schema: {error}")))?;
    Ok(conn)
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
        "tls": false,
        "note": "Bind loopback and terminate TLS at a reverse proxy before exposure."
    })))
}

async fn admin_page() -> Html<&'static str> {
    Html(ADMIN_HTML)
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
    let conn = state
        .db
        .lock()
        .map_err(|_| ApiError::internal("database lock poisoned"))?;
    let user: Option<(i64, String, String, String)> = conn
        .query_row(
            "SELECT id, username, password_hash, role FROM users WHERE username = ?1",
            params![request.username],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()
        .map_err(|error| ApiError::internal(format!("read login user: {error}")))?;
    let Some((id, username, password_hash, role)) = user else {
        increment_login_failure(&state, &request.username, now_v)?;
        return Err(ApiError::unauthorized("username or password is incorrect"));
    };
    let status: String = conn
        .query_row(
            "SELECT status FROM users WHERE id = ?1",
            params![id],
            |row| row.get(0),
        )
        .map_err(|error| ApiError::internal(format!("read user status: {error}")))?;
    if status != "active" {
        return Err(ApiError::forbidden("account is disabled"));
    }
    if !verify_password(&password_hash, &request.password) {
        increment_login_failure(&state, &request.username, now_v)?;
        return Err(ApiError::unauthorized("username or password is incorrect"));
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
                    d.fingerprint, d.capabilities, d.status, d.last_seen, d.created_at
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
        let parsed = serde_json::from_str::<Value>(&permissions)
            .unwrap_or(Value::String(permissions));
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
    let device_token = headers
        .get("x-device-token")
        .and_then(|value| value.to_str().ok())
        .map(|value| sha256_hex(value.as_bytes()));
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
    let allowed = bearer_user
        .as_ref()
        .map(|user| user.id == owner_id || user.role == "admin")
        .unwrap_or(false)
        || device_token
            .map(|hash| {
                conn.query_row(
                    "SELECT 1 FROM devices WHERE device_id=?1 AND device_token_hash=?2 AND status='active'",
                    params![device_id, hash],
                    |_| Ok(()),
                )
                .optional()
                .ok()
                .flatten()
                .is_some()
            })
            .unwrap_or(false);
    if !allowed {
        return Err(ApiError::unauthorized(
            "device token or owner session required",
        ));
    }
    let last_seen = now();
    conn.execute(
        "UPDATE devices SET last_seen=?1 WHERE device_id=?2",
        params![last_seen, device_id],
    )
    .map_err(|error| ApiError::internal(format!("update heartbeat: {error}")))?;
    Ok(Json(json!({"ok": true, "last_seen": last_seen})))
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

fn app_router(state: AppState) -> Router {
    Router::new()
        .route("/", get(admin_page))
        .route("/admin", get(admin_page))
        .route("/health", get(health))
        .route("/api/v1/server/info", get(server_info))
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
        .route("/api/v1/devices/{id}/revoke", post(revoke_device))
        .route("/api/v1/devices/{id}/heartbeat", post(heartbeat))
        .route("/api/v1/devices/{id}/connect-info", get(connect_info))
        .route(
            "/api/v1/devices/{id}/pairing-code",
            post(create_pairing_code),
        )
        .route("/api/v1/devices/{id}/grants", get(device_grants))
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
    let state = AppState {
        db: Arc::new(Mutex::new(conn)),
        started_at: now(),
        login_guard: Arc::new(Mutex::new(HashMap::new())),
    };
    let _started_at = state.started_at;
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
        let a = device_id_for("aa".repeat(32).as_str());
        let b = device_id_for("aa".repeat(32).as_str());
        assert_eq!(a, b);
        assert!(a.starts_with("yl-"));
    }
}
