#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

mod commands;

use commands::VpnState;

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    tauri::Builder::default()
        .manage(VpnState::new())
        .setup(|app| {
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(commands::run_control_server(handle));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::connect_vpn,
            commands::disconnect_vpn,
            commands::get_status,
            commands::open_campus_page,
            commands::probe_campus_page,
        ])
        .run(tauri::generate_context!())
        .expect("HUSE VPN desktop runtime failed");
}
