use std::sync::Arc;

use gpui::{App, AppContext as _, Application};
use tokio::runtime::Runtime;

use crate::{
    app::actions, app::state::SharedAppState, config::GlideConfig, platform::input::hotkey, ui,
    ui::menu, ui::overlay,
};

pub fn run() {
    let app = Application::new().with_assets(gpui_component_assets::Assets);

    // Reopen settings after startup; no-op while config recovery is active.
    app.on_reopen(move |cx| {
        actions::ensure_settings_window_if_initialized(cx);
    });

    app.run(move |cx| {
        gpui_component::init(cx);
        cx.activate(true);

        match GlideConfig::load_or_create() {
            Ok(config) => start_app(config, cx),
            Err(error) => ui::open_config_recovery_window(error.to_string(), start_app, cx),
        }
    });
}

fn start_app(config: GlideConfig, cx: &mut App) {
    let shared = Arc::new(SharedAppState::new(config));
    let runtime = Arc::new(Runtime::new().expect("failed to start async runtime"));

    crate::platform::preload_app_icons();
    crate::engines::prewarm::start_app_prewarm(shared.clone(), runtime.clone());
    crate::engines::model_catalog::fetch_all_models(&shared.snapshot().config.providers);
    actions::init(cx, shared.clone());
    actions::register(cx);
    actions::bind_keybindings(cx);
    menu::install(cx);

    // Apply saved theme preference at startup
    let snap = shared.snapshot();
    ui::apply_theme_preference(snap.config.app.theme, snap.config.app.accent, None, cx);
    hotkey::start_listener(shared.clone(), runtime);

    let overlay_shared = shared.clone();
    let overlay_entity = cx.new(|cx| {
        let controller = overlay::OverlayController::new(overlay_shared);
        controller.start_polling(cx);
        controller
    });
    cx.set_global(overlay::OverlayHandle::new(overlay_entity));
    actions::ensure_settings_window(cx);
}
