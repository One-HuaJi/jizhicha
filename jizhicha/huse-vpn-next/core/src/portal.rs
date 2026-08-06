//! Public Gateway portal authentication.
//!
//! This stage authenticates the school account against the VPN gateway's
//! `SAM-all` source. It is not authentication against either internal Web
//! application. A successful portal session is kept distinct from possession
//! of the native NC ticket.

use crate::error::{HuseVpnError, Result};
use crate::nc::decode_ticket_hex;
use aes::cipher::generic_array::GenericArray;
use aes::cipher::{BlockEncrypt, KeyInit};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use regex::Regex;
use reqwest::cookie::Jar;
use reqwest::header::LOCATION;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::sync::Arc;

const SAM_ALL: &str = "3=@@=SAM-all=@@=3=@@=SAM-all=@@=1=@@=0=@@=0=@@=0";

pub struct PortalClient {
    server: String,
    client: reqwest::Client,
    cookies: Arc<Jar>,
}

#[derive(Clone)]
pub struct PortalLogin {
    pub client: reqwest::Client,
    pub server: String,
    pub username: String,
    pub ticket: Option<[u8; 32]>,
    pub diagnostics: PortalDiagnostics,
}

#[derive(Debug, Clone, Serialize)]
pub struct PortalDiagnostics {
    pub initial_status: u16,
    pub login_status: u16,
    pub login_redirect_path: Option<String>,
    pub landing_path: String,
    pub landing_has_login_form: bool,
    pub landing_has_native_download: bool,
    pub authenticated_session: bool,
    pub ticket_sources: Vec<String>,
}

impl PortalClient {
    pub fn new(server: impl Into<String>) -> Result<Self> {
        let cookies = Arc::new(Jar::default());
        let client = reqwest::Client::builder()
            .danger_accept_invalid_certs(true)
            .cookie_provider(cookies.clone())
            .build()
            .map_err(|error| {
                HuseVpnError::Authentication(format!("cannot build HTTPS client: {error}"))
            })?;
        Ok(Self {
            server: server.into(),
            client,
            cookies,
        })
    }

    pub async fn login(&self, username: &str, password: &str) -> Result<PortalLogin> {
        if username.trim().is_empty() || password.is_empty() {
            return Err(HuseVpnError::Authentication(
                "student ID and password are required".into(),
            ));
        }

        let base = format!("https://{}", self.server);
        let initial = self.client.get(&base).send().await.map_err(|error| {
            HuseVpnError::Authentication(format!(
                "cannot reach public accelerator gateway: {error}"
            ))
        })?;
        let initial_status = initial.status().as_u16();
        let initial_body = initial.text().await.map_err(|error| {
            HuseVpnError::Authentication(format!("cannot read accelerator login page: {error}"))
        })?;
        let salt = extract_salt(&initial_body)?;
        let encrypted_password = encrypt_password(&salt, password)?;

        let login_client = reqwest::Client::builder()
            .danger_accept_invalid_certs(true)
            .cookie_provider(self.cookies.clone())
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|error| {
                HuseVpnError::Authentication(format!("cannot build login client: {error}"))
            })?;
        let login_url = format!("{base}/login_action.php?id=0");
        let response = login_client
            .post(&login_url)
            .header("Referer", format!("{base}/welcome.php"))
            .form(&[
                ("auth_server", SAM_ALL),
                ("subAuthName", "SAM-all"),
                ("user_name", username),
                ("pass", encrypted_password.as_str()),
                ("show_pass", ""),
            ])
            .send()
            .await
            .map_err(|error| {
                HuseVpnError::Authentication(format!(
                    "school accelerator login request failed: {error}"
                ))
            })?;

        let login_status = response.status();
        let headers = response.headers().clone();
        let login_redirect_path = headers
            .get(LOCATION)
            .and_then(|value| value.to_str().ok())
            .map(redacted_path);
        let login_body = response.text().await.map_err(|error| {
            HuseVpnError::Authentication(format!(
                "cannot read school accelerator login response: {error}"
            ))
        })?;
        if login_status.is_client_error()
            || login_status.is_server_error()
            || response_rejects_credentials(&login_body)
        {
            return Err(HuseVpnError::Authentication(
                "the gateway's SAM-all school account source rejected the credentials".into(),
            ));
        }

        let mut ticket_sources = Vec::new();
        let mut ticket = extract_ticket(&login_body);
        if ticket.is_some() {
            ticket_sources.push("login_body".to_string());
        }
        if ticket.is_none() {
            let header_text = headers
                .values()
                .filter_map(|value| value.to_str().ok())
                .collect::<Vec<_>>()
                .join("\n");
            ticket = extract_ticket(&header_text);
            if ticket.is_some() {
                ticket_sources.push("login_headers".to_string());
            }
        }

        let landing = self.client.get(&base).send().await.map_err(|error| {
            HuseVpnError::Authentication(format!("cannot verify accelerator session: {error}"))
        })?;
        let landing_path = landing.url().path().to_string();
        let landing_body = landing.text().await.map_err(|error| {
            HuseVpnError::Authentication(format!("cannot read accelerator landing page: {error}"))
        })?;
        // `welcome.php` is used by both pre-login and post-login variants on
        // this Gateway release. The captured login form itself is the reliable
        // rejection signal; the URL path alone is not.
        let landing_has_login_form = looks_like_login_form(&landing_body);
        let landing_has_native_download = landing_body.contains("GWSetup");
        let authenticated_session = !landing_has_login_form;
        if ticket.is_none() {
            ticket = extract_ticket(&landing_body);
            if ticket.is_some() {
                ticket_sources.push("landing_body".to_string());
            }
        }

        if ticket.is_none() {
            if let Ok(extra) = self
                .client
                .get(format!("{base}/fw/app_list.php"))
                .send()
                .await
            {
                if let Ok(body) = extra.text().await {
                    ticket = extract_ticket(&body);
                    if ticket.is_some() {
                        ticket_sources.push("fw_app_list".to_string());
                    }
                }
            }
        }

        Ok(PortalLogin {
            client: self.client.clone(),
            server: self.server.clone(),
            username: username.to_string(),
            ticket,
            diagnostics: PortalDiagnostics {
                initial_status,
                login_status: login_status.as_u16(),
                login_redirect_path,
                landing_path,
                landing_has_login_form,
                landing_has_native_download,
                authenticated_session,
                ticket_sources,
            },
        })
    }
}

fn response_rejects_credentials(body: &str) -> bool {
    body.contains("ret_code=-1")
        || body.contains("登录失败")
        || body.contains("用户名或密码错误")
        || body.contains("密码错误")
}

fn looks_like_login_form(body: &str) -> bool {
    body.contains("name=\"login_form\"")
        || body.contains("id=\"login_form\"")
        || body.contains("login_action.php?id=0") && body.contains("name=\"pass\"")
}

fn redacted_path(location: &str) -> String {
    let path = location.split(['?', '#']).next().unwrap_or(location);
    if path.is_empty() {
        "/".to_string()
    } else {
        path.to_string()
    }
}

fn extract_salt(body: &str) -> Result<String> {
    let regex = Regex::new(r#"password_encrypt\(\s*["']([0-9]+)["']"#)
        .map_err(|error| HuseVpnError::Protocol(format!("salt regex failed: {error}")))?;
    regex
        .captures(body)
        .and_then(|captures| captures.get(1))
        .map(|value| value.as_str().to_string())
        .ok_or_else(|| {
            HuseVpnError::Authentication(
                "the public gateway page did not contain its password salt".into(),
            )
        })
}

fn extract_ticket(text: &str) -> Option<[u8; 32]> {
    let regex = Regex::new(r"(?is)ticket.{0,160}?([0-9a-f]{64})").ok()?;
    let ticket = regex
        .captures_iter(text)
        .find_map(|captures| decode_ticket_hex(captures.get(1)?.as_str()).ok());
    ticket
}

fn generate_key(salt: &str) -> String {
    let mut transformed = String::new();
    for character in salt.chars() {
        let original = character as i32;
        let digit_character = if character == '0' { '9' } else { character };
        let digit = digit_character.to_digit(10).unwrap_or(0) as i32;
        let mut delta = original % digit.max(1);
        if digit_character == '1' {
            delta = original << 1;
        }
        if digit_character == '2' {
            delta = original ^ 2;
        }
        let mut output = original + delta;
        if output < 0x21 {
            output = 0x21 + original % delta.max(1);
        }
        if output > 0x7e {
            output = 0x7e - original % delta.max(1);
        }
        if let Some(character) = char::from_u32(output as u32) {
            transformed.push(character);
        }
    }
    let digest = Sha256::digest(transformed.as_bytes());
    hex::encode(digest)[..32].to_string()
}

fn encrypt_password(salt: &str, password: &str) -> Result<String> {
    let key_text = generate_key(salt);
    let iv_text = hex::encode(Sha256::digest(key_text.as_bytes()))[..16].to_string();
    let cipher = aes::Aes256::new(GenericArray::from_slice(key_text.as_bytes()));
    let mut previous = *GenericArray::from_slice(iv_text.as_bytes());
    let padding = 16 - password.len() % 16;
    let mut input = password.as_bytes().to_vec();
    input.extend(std::iter::repeat(padding as u8).take(padding));
    let mut encrypted = Vec::with_capacity(input.len());
    for chunk in input.chunks_exact(16) {
        let mut block = GenericArray::clone_from_slice(chunk);
        for index in 0..16 {
            block[index] ^= previous[index];
        }
        cipher.encrypt_block(&mut block);
        encrypted.extend_from_slice(&block);
        previous = block;
    }
    Ok(BASE64.encode(encrypted))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fictitious_password_vector_matches_gateway_javascript() {
        assert_eq!(
            generate_key("1234567890"),
            "3704dfc01ace8eb7d6235ac763b9ffd9"
        );
        assert_eq!(
            encrypt_password("1234567890", "not-a-real-password").unwrap(),
            "Ekrj0/LPh3z8ovX9awLLdRnVcewSGDjCr3BG2i/fNWE="
        );
    }

    #[test]
    fn extracts_ticket_without_exposing_it_in_diagnostics() {
        let value = "0123456789abcdef".repeat(4);
        assert!(extract_ticket(&format!("Ticket={value}")).is_some());
        assert_eq!(redacted_path(&format!("/launch?ticket={value}")), "/launch");
    }

    #[test]
    fn detects_the_captured_login_form() {
        assert!(looks_like_login_form(
            r#"<form id="login_form" action="login_action.php?id=0"><input name="pass"></form>"#
        ));
    }
}
