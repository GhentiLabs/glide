use gpui::prelude::*;
use gpui::{
    App, Window, WindowBackgroundAppearance, WindowBounds, WindowKind, WindowOptions, div, px, size,
};
use gpui_component::ActiveTheme;
use gpui_component::button::{Button, ButtonVariants};
use gpui_component::scroll::ScrollableElement;

use crate::config::GlideConfig;

type RecoveryComplete = fn(GlideConfig, &mut App);

pub(crate) fn open_config_recovery_window(
    error: String,
    on_recovered: RecoveryComplete,
    cx: &mut App,
) {
    let _ = cx.open_window(
        WindowOptions {
            window_bounds: Some(WindowBounds::centered(size(px(540.0), px(340.0)), cx)),
            titlebar: None,
            kind: WindowKind::PopUp,
            window_background: WindowBackgroundAppearance::Transparent,
            is_resizable: false,
            is_minimizable: false,
            ..Default::default()
        },
        move |window, cx| {
            window.set_window_title("Glide Config Error");
            cx.new(|_| ConfigRecoveryView::new(error, on_recovered))
        },
    );
}

struct ConfigRecoveryView {
    load_error: String,
    reset_error: Option<String>,
    on_recovered: RecoveryComplete,
}

impl ConfigRecoveryView {
    fn new(load_error: String, on_recovered: RecoveryComplete) -> Self {
        Self {
            load_error,
            reset_error: None,
            on_recovered,
        }
    }
}

impl Render for ConfigRecoveryView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let config_path = GlideConfig::config_file_path()
            .map(|path| path.display().to_string())
            .ok();

        let mut panel = div()
            .flex()
            .flex_col()
            .gap_3()
            .size_full()
            .p(px(20.0))
            .rounded_lg()
            .border_1()
            .border_color(cx.theme().border)
            .bg(cx.theme().background)
            .shadow_lg()
            .child(
                div()
                    .text_lg()
                    .font_weight(gpui::FontWeight::BOLD)
                    .text_color(cx.theme().foreground)
                    .child("Glide could not load your config"),
            )
            .child(
                div()
                    .text_sm()
                    .text_color(cx.theme().muted_foreground)
                    .child(
                        "The config file appears to be invalid or unreadable. \
                         Resetting creates a fresh default config and keeps a backup of the old file.",
                    ),
            );

        if let Some(config_path) = config_path {
            panel = panel.child(
                div()
                    .text_xs()
                    .text_color(cx.theme().muted_foreground)
                    .child(config_path),
            );
        }

        panel = panel.child(
            div()
                .text_xs()
                .p_3()
                .flex_1()
                .overflow_y_scrollbar()
                .rounded_md()
                .border_1()
                .border_color(cx.theme().border)
                .bg(cx.theme().secondary)
                .text_color(cx.theme().foreground)
                .child(self.load_error.clone()),
        );

        if let Some(reset_error) = &self.reset_error {
            panel = panel.child(
                div()
                    .text_xs()
                    .p_3()
                    .rounded_md()
                    .border_1()
                    .border_color(cx.theme().danger)
                    .text_color(cx.theme().danger)
                    .child(reset_error.clone()),
            );
        }

        panel = panel.child(
            div()
                .flex()
                .justify_end()
                .gap_2()
                .child(
                    Button::new("quit-after-config-error")
                        .label("Quit")
                        .ghost()
                        .on_click(|_, _, cx| cx.quit()),
                )
                .child(
                    Button::new("reset-config")
                        .label("Reset Config")
                        .danger()
                        .on_click(cx.listener(|this, _, window, cx| {
                            match GlideConfig::reset_to_default()
                                .and_then(|_| GlideConfig::load_or_create())
                            {
                                Ok(config) => {
                                    window.remove_window();
                                    (this.on_recovered)(config, cx);
                                }
                                Err(error) => {
                                    this.reset_error =
                                        Some(format!("Failed to reset config: {error:#}"));
                                    cx.notify();
                                }
                            }
                        })),
                ),
        );

        div()
            .flex()
            .items_center()
            .justify_center()
            .size_full()
            .p(px(16.0))
            .bg(gpui::transparent_black())
            .font_family(cx.theme().font_family.clone())
            .text_color(cx.theme().foreground)
            .child(panel)
    }
}
