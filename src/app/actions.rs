use std::sync::Arc;

use gpui::{
    AnyWindowHandle, App, AppContext as _, Bounds, Global, KeyBinding, Window, WindowBounds,
    WindowOptions, actions, point, px, size,
};
use gpui_component::Root;

use crate::{app::state::SharedAppState, ui};
// A lot of these actions are just so we can define the menu bar for macOS
// (kinda dumb but no menu bar/standard actions is worse sooo...)
actions!(
    glide,
    [
        Quit,
        CloseWindow,
        ShowSettings,
        ShowAbout,
        Minimize,
        Zoom,
        Undo,
        Redo,
        Cut,
        Copy,
        Paste,
        SelectAll
    ]
);

/// Tracks the settings window so we can reopen/close it specifically.
// GPUI/macOS does not give this window a stable app-level identity for us.
struct SettingsWindowState {
    handle: Option<AnyWindowHandle>,
    shared: Arc<SharedAppState>,
}

impl Global for SettingsWindowState {}

pub(crate) fn init(cx: &mut App, shared: Arc<SharedAppState>) {
    cx.set_global(SettingsWindowState {
        handle: None,
        shared,
    });
}

pub(crate) fn register(cx: &mut App) {
    cx.on_action(|_: &Quit, cx| cx.quit());
    cx.on_action(|_: &CloseWindow, cx| close_settings_window(cx));
    cx.on_action(|_: &ShowSettings, cx| ensure_settings_window(cx));
    cx.on_action(|_: &ShowAbout, cx| open_about_window(cx));
    cx.on_action(|_: &Minimize, cx| minimize_active_window(cx));
    cx.on_action(|_: &Zoom, cx| zoom_active_window(cx));
}

pub(crate) fn bind_keybindings(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("cmd-q", Quit, None),
        KeyBinding::new("cmd-w", CloseWindow, None),
        KeyBinding::new("cmd-m", Minimize, None),
    ]);
}

pub(crate) fn ensure_settings_window(cx: &mut App) {
    if activate_existing_settings_window(cx) {
        return;
    }

    if let Some(handle) = open_settings_window(cx) {
        cx.global_mut::<SettingsWindowState>().handle = Some(handle);
    }
}

pub(crate) fn ensure_settings_window_if_initialized(cx: &mut App) {
    if cx.has_global::<SettingsWindowState>() {
        ensure_settings_window(cx);
    }
}

fn close_settings_window(cx: &mut App) {
    let handle = cx.global::<SettingsWindowState>().handle;
    if let Some(handle) = handle {
        cx.defer(move |cx| {
            let _ = handle.update(cx, |_, window, _| window.remove_window());
            cx.global_mut::<SettingsWindowState>().handle = None;
        });
    }
}

fn open_about_window(cx: &mut App) {
    let shared = cx.global::<SettingsWindowState>().shared.clone();

    let _ = cx.open_window(
        WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                point(px(0.0), px(0.0)),
                size(px(240.0), px(200.0)),
            ))),
            is_resizable: false,
            ..Default::default()
        },
        move |window, cx| {
            window.set_window_title("About Glide");
            cx.new(move |cx| {
                let view = cx.new(move |_| ui::AboutView::new(shared));
                let any_view: gpui::AnyView = view.into();
                Root::new(any_view, window, cx)
            })
        },
    );
}

fn minimize_active_window(cx: &mut App) {
    update_active_window(cx, Window::minimize_window);
}

fn zoom_active_window(cx: &mut App) {
    update_active_window(cx, Window::zoom_window);
}

fn activate_existing_settings_window(cx: &mut App) -> bool {
    let handle = cx.global::<SettingsWindowState>().handle;

    if let Some(handle) = handle {
        return handle
            .update(cx, |_, window, _| window.activate_window())
            .is_ok();
    }

    false
}

fn open_settings_window(cx: &mut App) -> Option<AnyWindowHandle> {
    let shared = cx.global::<SettingsWindowState>().shared.clone();
    let shared_for_view = shared.clone();

    cx.open_window(
        WindowOptions {
            window_bounds: Some(WindowBounds::centered(size(px(1000.0), px(650.0)), cx)),
            window_min_size: Some(size(px(700.0), px(450.0))),
            ..Default::default()
        },
        |window, cx| {
            window.set_window_title("Glide");
            let view = cx.new(|cx| ui::SettingsApp::new(shared_for_view, window, cx));
            let any_view: gpui::AnyView = view.into();
            cx.new(|cx| Root::new(any_view, window, cx))
        },
    )
    .ok()
    .map(Into::into)
}

fn update_active_window(cx: &mut App, update: impl FnOnce(&Window)) {
    if let Some(stack) = cx.window_stack()
        && let Some(window) = stack.into_iter().next()
    {
        let _ = window.update(cx, |_, window, _| update(window));
    }
}
