//! Mitigations for macOS 26 (Tahoe) menu bar state corruption.
//!
//! macOS 26 hosts third-party status items through ControlCenter, and its
//! per-app bookkeeping can corrupt (notably on 26.5), leaving the tray icon
//! hidden or parked off-screen while the app believes everything is fine.
//! See <https://github.com/robinebers/openusage/issues/517>.
//!
//! Mirrors the fixes shipped by other affected menu bar apps:
//! 1. Drop `NSStatusItem Visible* = false` defaults before the tray is
//!    created, so a stale "hidden" record cannot suppress the icon (CodexBar).
//! 2. Give the status item an explicit autosave name, which re-registers
//!    affected installs under a fresh ControlCenter identity (oMLX).
//! 3. Probe the status item after startup and, if macOS is not actually
//!    hosting it in the menu bar, tell the user how to recover (oMLX) —
//!    the tray is the app's only entry point.

use objc2_app_kit::NSAlert;
use objc2_foundation::{MainThreadMarker, NSNumber, NSProcessInfo, NSString, NSUserDefaults};
use tauri::AppHandle;

/// Stable ControlCenter identity for the status item. Bumping this value
/// re-registers every install under a fresh identity, which is the escape
/// hatch when macOS corrupts the saved state for the current one.
const STATUS_ITEM_AUTOSAVE_NAME: &str = "OpenUsage";

/// Identity macOS auto-generates when no autosave name is set (all builds
/// before the explicit name above was introduced).
const LEGACY_ITEM_NAME: &str = "Item-0";

const PREFERRED_POSITION_KEY_PREFIX: &str = "NSStatusItem Preferred Position";
const VISIBLE_KEY_PREFIXES: [&str; 2] = ["NSStatusItem Visible", "NSStatusItem VisibleCC"];

const INITIAL_PROBE_DELAY: std::time::Duration = std::time::Duration::from_secs(5);
const CONFIRM_PROBE_DELAY: std::time::Duration = std::time::Duration::from_secs(10);

/// Call before the tray icon is created.
pub fn prepare_status_item_defaults() {
    let defaults = NSUserDefaults::standardUserDefaults();

    // A `Visible* = false` record left behind by Tahoe's menu bar migration
    // keeps the icon hidden on every launch. Only `false` entries are stale;
    // `true` and unrelated entries are left alone.
    for item_name in [LEGACY_ITEM_NAME, STATUS_ITEM_AUTOSAVE_NAME] {
        for key_prefix in VISIBLE_KEY_PREFIXES {
            let key = NSString::from_str(&format!("{key_prefix} {item_name}"));
            let Some(value) = defaults.objectForKey(&key) else {
                continue;
            };
            let is_stale_false = value
                .downcast::<NSNumber>()
                .map(|number| !number.boolValue())
                .unwrap_or(false);
            if is_stale_false {
                log::warn!("clearing stale '{key_prefix} {item_name}' menu bar default");
                defaults.removeObjectForKey(&key);
            }
        }
    }

    // Carry the saved menu bar position over to the new identity so existing
    // installs keep their slot when the autosave name is adopted.
    let legacy_position_key =
        NSString::from_str(&format!("{PREFERRED_POSITION_KEY_PREFIX} {LEGACY_ITEM_NAME}"));
    let position_key = NSString::from_str(&format!(
        "{PREFERRED_POSITION_KEY_PREFIX} {STATUS_ITEM_AUTOSAVE_NAME}"
    ));
    if defaults.objectForKey(&position_key).is_none()
        && let Some(position) = defaults.objectForKey(&legacy_position_key)
    {
        unsafe { defaults.setObject_forKey(Some(&position), &position_key) };
    }
}

/// Call after the tray icon is created. tray-icon leaves the status item on
/// the auto-generated "Item-N" identity — exactly the record Tahoe corrupts.
pub fn adopt_stable_identity(tray: &tauri::tray::TrayIcon) {
    let result = tray.with_inner_tray_icon(|inner| {
        let Some(status_item) = inner.ns_status_item() else {
            return false;
        };
        status_item.setAutosaveName(Some(&NSString::from_str(STATUS_ITEM_AUTOSAVE_NAME)));
        true
    });
    match result {
        Ok(true) => {}
        Ok(false) => log::error!("status item unavailable while adopting autosave name"),
        Err(error) => log::error!("failed to adopt status item autosave name: {error}"),
    }
}

/// Run once after startup, macOS 26+ only: probe twice (ControlCenter needs
/// time to settle after launch) and surface recovery guidance if the icon
/// never lands in the menu bar.
pub fn schedule_health_check(app_handle: &AppHandle) {
    if NSProcessInfo::processInfo()
        .operatingSystemVersion()
        .majorVersion
        < 26
    {
        return;
    }
    let app_handle = app_handle.clone();
    std::thread::spawn(move || {
        std::thread::sleep(INITIAL_PROBE_DELAY);
        let Some(first) = probe_status_item(&app_handle) else {
            return;
        };
        if !first.is_broken() {
            log::debug!("status item health check passed: {first:?}");
            return;
        }
        log::warn!("status item looks broken ({first:?}); re-checking before alerting");
        std::thread::sleep(CONFIRM_PROBE_DELAY);
        let Some(second) = probe_status_item(&app_handle) else {
            return;
        };
        if !second.is_broken() {
            log::info!("status item recovered on second probe: {second:?}");
            return;
        }
        log::error!(
            "status item is not hosted in the menu bar ({second:?}); macOS 26 menu bar state for this app is likely corrupted (issue #517)"
        );
        show_recovery_alert(&app_handle);
    });
}

#[derive(Clone, Copy, Debug)]
struct StatusItemHealth {
    visible: bool,
    has_button: bool,
    has_window: bool,
    has_screen: bool,
    /// AppKit y-origin of the button window; the corrupted state parks it at
    /// a negative value (below the screen). Only read through the `Debug`
    /// output in logs.
    #[allow(dead_code)]
    window_y: f64,
}

impl StatusItemHealth {
    /// Broken when the app-side handle looks alive but macOS is not actually
    /// hosting the item on any screen (or reports it hidden).
    fn is_broken(&self) -> bool {
        !(self.visible && self.has_button && self.has_window && self.has_screen)
    }
}

fn probe_status_item(app_handle: &AppHandle) -> Option<StatusItemHealth> {
    let Some(tray) = app_handle.tray_by_id("tray") else {
        log::error!("tray handle missing during status item health check");
        return None;
    };
    let health = tray.with_inner_tray_icon(|inner| {
        // The closure is dispatched to the main thread by tauri.
        let mtm = MainThreadMarker::new()?;
        let status_item = inner.ns_status_item()?;
        let button = status_item.button(mtm);
        let window = button.as_ref().and_then(|button| button.window());
        let screen = window.as_ref().and_then(|window| window.screen());
        Some(StatusItemHealth {
            visible: status_item.isVisible(),
            has_button: button.is_some(),
            has_window: window.is_some(),
            has_screen: screen.is_some(),
            window_y: window
                .map(|window| window.frame().origin.y)
                .unwrap_or(f64::NAN),
        })
    });
    match health {
        Ok(Some(health)) => Some(health),
        Ok(None) => {
            log::error!("status item probe could not run (no status item handle)");
            None
        }
        Err(error) => {
            log::error!("status item probe failed: {error}");
            None
        }
    }
}

fn show_recovery_alert(app_handle: &AppHandle) {
    let result = app_handle.run_on_main_thread(|| {
        let Some(mtm) = MainThreadMarker::new() else {
            return;
        };
        let alert = NSAlert::new(mtm);
        alert.setMessageText(&NSString::from_str("Menu Bar Icon Hidden by macOS"));
        alert.setInformativeText(&NSString::from_str(
            "macOS is not displaying the OpenUsage menu bar icon. This is caused by a menu bar bug in macOS 26 (Tahoe).\n\nTo fix it:\n\n1. Open System Settings → Menu Bar\n2. Find OpenUsage under \"Allow in the Menu Bar\" and toggle it off and back on\n3. Restart OpenUsage\n\nIf the icon is still missing, please report it at github.com/robinebers/openusage/issues/517",
        ));
        alert.runModal();
    });
    if let Err(error) = result {
        log::error!("failed to show menu bar recovery alert: {error}");
    }
}

#[cfg(test)]
mod tests {
    use super::StatusItemHealth;

    fn healthy() -> StatusItemHealth {
        StatusItemHealth {
            visible: true,
            has_button: true,
            has_window: true,
            has_screen: true,
            window_y: 1093.0,
        }
    }

    #[test]
    fn healthy_item_is_not_broken() {
        assert!(!healthy().is_broken());
    }

    #[test]
    fn off_screen_item_is_broken() {
        // The #517 signature: window exists but is not attached to any screen.
        let health = StatusItemHealth {
            has_screen: false,
            window_y: -22.0,
            ..healthy()
        };
        assert!(health.is_broken());
    }

    #[test]
    fn hidden_item_is_broken() {
        let health = StatusItemHealth {
            visible: false,
            ..healthy()
        };
        assert!(health.is_broken());
    }

    #[test]
    fn blocked_item_without_window_is_broken() {
        // Tahoe allow-list blocking: the button never gets a window.
        let health = StatusItemHealth {
            has_window: false,
            has_screen: false,
            ..healthy()
        };
        assert!(health.is_broken());
    }
}
