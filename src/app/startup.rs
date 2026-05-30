use std::sync::Arc;

use gpui::{AppContext as _, Application};
use tokio::runtime::Runtime;

use crate::{
    app::actions, app::state::SharedAppState, config::GlideConfig, platform::input::hotkey,
    platform::permissions, ui, ui::menu, ui::overlay,
};

pub fn run() {
    permissions::request_accessibility_access_once();

    let config = GlideConfig::load_or_create().expect("failed to load config");
    let shared = Arc::new(SharedAppState::new(config));
    shared.refresh_input_devices();

    let runtime = Arc::new(Runtime::new().expect("failed to start async runtime"));
    crate::engines::local_models::prewarm::start_app_prewarm(shared.clone(), runtime.clone());

    crate::platform::preload_app_icons();
    crate::engines::model_catalog::fetch_all_models(&shared.snapshot().config.providers);

    let app = Application::new().with_assets(gpui_component_assets::Assets);

    // Reopen settings window when dock icon clicked with no windows visible
    app.on_reopen(move |cx| {
        actions::ensure_settings_window(cx);
    });

    app.run(move |cx| {
        gpui_component::init(cx);
        cx.activate(true);

        actions::init(cx, shared.clone());
        // Apply saved theme preference at startup
        let snap = shared.snapshot();
        ui::apply_theme_preference(snap.config.app.theme, snap.config.app.accent, None, cx);

        // --- Actions, key bindings, and menu bar ---
        actions::register(cx);
        actions::bind_keybindings(cx);
        menu::install(cx);

        // --- Background services ---
        hotkey::start_listener(shared.clone(), runtime);

        let overlay_shared = shared.clone();
        let overlay_entity = cx.new(|cx| {
            let controller = overlay::OverlayController::new(overlay_shared);
            controller.start_polling(cx);
            controller
        });
        cx.set_global(overlay::OverlayHandle::new(overlay_entity));

        // --- Open initial settings window ---
        actions::ensure_settings_window(cx);
    });
}
