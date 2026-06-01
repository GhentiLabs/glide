use std::time::Duration;

use gpui::prelude::*;
use gpui::{Animation, AnimationExt as _, App, SharedString, div, percentage};
use gpui_component::ActiveTheme;
use gpui_component::Sizable;
use gpui_component::button::{Button, ButtonVariants};
use gpui_component::{Icon, IconName};

use crate::config::{GlideConfig, Provider};

use super::super::SettingsApp;

pub(super) fn animated_loader(id: SharedString) -> impl IntoElement {
    Icon::new(IconName::Loader).xsmall().with_animation(
        id,
        Animation::new(Duration::from_millis(900)).repeat(),
        |icon, delta| icon.rotate(percentage(delta)),
    )
}

/// Shared wrapper for every model row: bordered card with a label/detail column
/// on the left and a caller-supplied trailing element (status or action) on the
/// right.
fn model_row_container(
    label: &str,
    detail: &str,
    trailing: impl IntoElement,
    cx: &App,
) -> gpui::Div {
    div()
        .w_full()
        .flex()
        .items_center()
        .gap_3()
        .px_3()
        .py_2()
        .rounded_md()
        .border_1()
        .border_color(cx.theme().border)
        .bg(cx.theme().secondary)
        .child(
            div()
                .flex()
                .flex_col()
                .gap_0p5()
                .flex_1()
                .min_w_0()
                .child(
                    div()
                        .text_sm()
                        .font_weight(gpui::FontWeight::MEDIUM)
                        .text_color(cx.theme().foreground)
                        .truncate()
                        .child(label.to_string()),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(cx.theme().muted_foreground)
                        .truncate()
                        .child(detail.to_string()),
                ),
        )
        .child(trailing)
}

/// Right-aligned action slot used by the downloadable asset rows.
fn action_slot(action: impl IntoElement) -> gpui::Div {
    div()
        .flex()
        .items_center()
        .justify_end()
        .flex_shrink_0()
        .child(action)
}

/// Spinner + muted label, shared by the `Downloading` / `Cancelling` arms.
fn spinner_cell(spinner_id: SharedString, label: impl Into<String>, cx: &App) -> gpui::Div {
    div()
        .flex()
        .items_center()
        .gap_2()
        .child(animated_loader(spinner_id))
        .child(
            div()
                .text_xs()
                .text_color(cx.theme().muted_foreground)
                .child(label.into()),
        )
}

/// Danger-colored error text + caller-supplied retry control, shared by the
/// `Failed` arms.
fn error_cell(error: String, retry: impl IntoElement, cx: &App) -> gpui::Div {
    div()
        .flex()
        .items_center()
        .gap_2()
        .child(
            div()
                .max_w(gpui::px(220.0))
                .text_xs()
                .text_color(cx.theme().danger)
                .child(error),
        )
        .child(retry)
}

/// When a model asset is deleted, drop it from the active dictation selection and
/// any per-style override so the config never points at a missing model.
fn clear_deleted_stt_selection(config: &mut GlideConfig, provider: Provider, deleted: &str) {
    if config.dictation.stt.provider == provider
        && config.dictation.stt.model == deleted
        && let Some(default) = crate::engines::model_catalog::smart_stt_default()
    {
        config.dictation.stt = default;
    }
    for style in &mut config.dictation.styles {
        if style
            .stt
            .as_ref()
            .map(|selection| selection.provider == provider && selection.model == deleted)
            .unwrap_or(false)
        {
            style.stt = None;
        }
    }
}

pub(super) fn local_model_row(
    label: &str,
    detail: &str,
    available: bool,
    reason: &str,
    cx: &mut gpui::Context<SettingsApp>,
) -> gpui::Div {
    let status = if available {
        div()
            .flex()
            .items_center()
            .gap_1()
            .flex_shrink_0()
            .child(
                Icon::new(IconName::Check)
                    .xsmall()
                    .text_color(gpui::rgb(0x22C55E)),
            )
            .child(
                div()
                    .text_xs()
                    .text_color(cx.theme().muted_foreground)
                    .child("Available"),
            )
            .into_any_element()
    } else {
        div()
            .flex()
            .items_center()
            .gap_1()
            .flex_shrink_0()
            .child(
                Icon::new(IconName::CircleX)
                    .xsmall()
                    .text_color(cx.theme().muted_foreground),
            )
            .child(
                div()
                    .max_w(gpui::px(220.0))
                    .text_xs()
                    .text_color(cx.theme().muted_foreground)
                    .truncate()
                    .child(reason.to_string()),
            )
            .into_any_element()
    };

    model_row_container(label, detail, status, cx)
}

pub(super) fn apple_speech_progress_label(progress: Option<f64>) -> String {
    progress
        .map(|progress| format!("{:.0}%", (progress * 100.0).clamp(0.0, 100.0)))
        .unwrap_or_else(|| "Preparing".to_string())
}

pub(super) fn apple_speech_model_row(
    status: crate::engines::model_assets::AppleSpeechModelStatus,
    show_not_installed: bool,
    entity: gpui::WeakEntity<SettingsApp>,
    cx: &mut gpui::App,
) -> Option<gpui::Div> {
    let model_id = status.definition.id.clone();
    let detail = if status.definition.locale_id.is_empty() {
        status.definition.asset_status.clone()
    } else {
        format!(
            "{} · {}",
            status.definition.locale_id, status.definition.asset_status
        )
    };

    let action = match status.state.clone() {
        crate::engines::model_assets::AppleSpeechInstallState::NotInstalled => {
            if !show_not_installed {
                return None;
            }
            let model_id = model_id.clone();
            let entity = entity.clone();
            Button::new(SharedString::from(format!("download-apple-{model_id}")))
                .label("Download")
                .icon(IconName::ArrowDown)
                .small()
                .compact()
                .on_click(move |_, _, cx| {
                    let _ =
                        crate::engines::model_assets::start_apple_speech_model_download(&model_id);
                    let _ = entity.update(cx, |_this, cx| {
                        poll_apple_speech_downloads(cx);
                        cx.notify();
                    });
                })
                .into_any_element()
        }
        crate::engines::model_assets::AppleSpeechInstallState::Downloading { progress } => {
            spinner_cell(
                SharedString::from(format!("apple-download-spinner-{model_id}")),
                apple_speech_progress_label(progress),
                cx,
            )
            .into_any_element()
        }
        crate::engines::model_assets::AppleSpeechInstallState::Cancelling => spinner_cell(
            SharedString::from(format!("apple-cancel-spinner-{model_id}")),
            "Cancelling...",
            cx,
        )
        .into_any_element(),
        crate::engines::model_assets::AppleSpeechInstallState::Installed => {
            let model_id = model_id.clone();
            let entity = entity.clone();
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(
                    div()
                        .text_xs()
                        .text_color(cx.theme().muted_foreground)
                        .child("Installed"),
                )
                .child(
                    Button::new(SharedString::from(format!("delete-apple-{model_id}")))
                        .icon(IconName::Close)
                        .small()
                        .compact()
                        .ghost()
                        .tooltip("Delete locale")
                        .on_click(move |_, _, cx| {
                            let _ =
                                crate::engines::model_assets::release_apple_speech_model(&model_id);
                            let deleted_model = model_id.clone();
                            let _ = entity.update(cx, |this, cx| {
                                let _ = this.shared.update_config(|config| {
                                    clear_deleted_stt_selection(
                                        config,
                                        Provider::AppleLocal,
                                        &deleted_model,
                                    );
                                });
                                cx.notify();
                            });
                        }),
                )
                .into_any_element()
        }
        crate::engines::model_assets::AppleSpeechInstallState::Failed(error) => {
            let model_id = model_id.clone();
            let entity = entity.clone();
            error_cell(
                error,
                Button::new(SharedString::from(format!("retry-apple-{model_id}")))
                    .label("Retry")
                    .small()
                    .compact()
                    .on_click(move |_, _, cx| {
                        let _ = crate::engines::model_assets::start_apple_speech_model_download(
                            &model_id,
                        );
                        let _ = entity.update(cx, |_this, cx| {
                            poll_apple_speech_downloads(cx);
                            cx.notify();
                        });
                    }),
                cx,
            )
            .into_any_element()
        }
    };

    Some(model_row_container(
        &status.definition.display_name,
        &detail,
        action_slot(action),
        cx,
    ))
}

pub(super) fn parakeet_model_row(
    status: crate::engines::model_assets::ParakeetModelStatus,
    cx: &mut gpui::Context<SettingsApp>,
) -> gpui::Div {
    let model_id = status.definition.id.to_string();
    let state = status.state.clone();
    let action = match state {
        crate::engines::model_assets::ParakeetInstallState::NotInstalled => {
            let model_id = model_id.clone();
            Button::new(SharedString::from(format!("download-{model_id}")))
                .label("Download")
                .icon(IconName::ArrowDown)
                .small()
                .compact()
                .on_click(cx.listener(move |_this, _, _window, cx| {
                    let _ = crate::engines::model_assets::start_parakeet_download(&model_id);
                    poll_parakeet_downloads(cx);
                    cx.notify();
                }))
                .into_any_element()
        }
        crate::engines::model_assets::ParakeetInstallState::Downloading {
            downloaded_bytes,
            total_bytes,
        } => {
            let cancel_model_id = model_id.clone();
            let label = if let Some(total) = total_bytes {
                format!(
                    "{} / {}",
                    format_bytes(downloaded_bytes),
                    format_bytes(total)
                )
            } else {
                format!("{} downloaded", format_bytes(downloaded_bytes))
            };
            spinner_cell(
                SharedString::from(format!("download-spinner-{model_id}")),
                label,
                cx,
            )
            .child(
                Button::new(SharedString::from(format!("cancel-{model_id}")))
                    .icon(IconName::Close)
                    .small()
                    .compact()
                    .ghost()
                    .tooltip("Cancel download")
                    .on_click(cx.listener(move |_this, _, _window, cx| {
                        let _ = crate::engines::model_assets::cancel_parakeet_download(
                            &cancel_model_id,
                        );
                        poll_parakeet_downloads(cx);
                        cx.notify();
                    })),
            )
            .into_any_element()
        }
        crate::engines::model_assets::ParakeetInstallState::Cancelling { .. } => spinner_cell(
            SharedString::from(format!("cancel-spinner-{model_id}")),
            "Cancelling...",
            cx,
        )
        .into_any_element(),
        crate::engines::model_assets::ParakeetInstallState::Installed { size_bytes } => {
            let model_id = model_id.clone();
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(
                    div()
                        .text_xs()
                        .text_color(cx.theme().muted_foreground)
                        .child(format_bytes(size_bytes)),
                )
                .child(
                    Button::new(SharedString::from(format!("delete-{model_id}")))
                        .icon(IconName::Close)
                        .small()
                        .compact()
                        .danger()
                        .tooltip("Delete model")
                        .on_click(cx.listener(move |this, _, _window, cx| {
                            let _ = crate::engines::model_assets::delete_parakeet_model(&model_id);
                            let deleted_model = model_id.clone();
                            let _ = this.shared.update_config(|config| {
                                clear_deleted_stt_selection(
                                    config,
                                    Provider::Parakeet,
                                    &deleted_model,
                                );
                            });
                            cx.notify();
                        })),
                )
                .into_any_element()
        }
        crate::engines::model_assets::ParakeetInstallState::Failed(error) => {
            let model_id = model_id.clone();
            error_cell(
                error,
                Button::new(SharedString::from(format!("retry-{model_id}")))
                    .label("Retry")
                    .small()
                    .compact()
                    .on_click(cx.listener(move |_this, _, _window, cx| {
                        let _ = crate::engines::model_assets::start_parakeet_download(&model_id);
                        poll_parakeet_downloads(cx);
                        cx.notify();
                    })),
                cx,
            )
            .into_any_element()
        }
    };

    model_row_container(
        status.definition.label,
        status.definition.language,
        action_slot(action),
        cx,
    )
}

/// Notify the settings view every 750 ms until `is_active` reports no in-flight
/// downloads, so download progress and completion render live.
fn poll_downloads(cx: &mut gpui::Context<SettingsApp>, is_active: fn() -> bool) {
    cx.spawn(async move |this, cx| {
        loop {
            cx.background_executor()
                .timer(Duration::from_millis(750))
                .await;
            let downloading = is_active();
            let _ = this.update(cx, |_this, cx| cx.notify());
            if !downloading {
                break;
            }
        }
    })
    .detach();
}

pub(super) fn poll_parakeet_downloads(cx: &mut gpui::Context<SettingsApp>) {
    poll_downloads(
        cx,
        crate::engines::model_assets::parakeet_has_active_downloads,
    );
}

pub(super) fn poll_apple_speech_downloads(cx: &mut gpui::Context<SettingsApp>) {
    poll_downloads(
        cx,
        crate::engines::model_assets::apple_speech_has_active_downloads,
    );
}

pub(super) fn format_bytes(bytes: u64) -> String {
    const KIB: f64 = 1024.0;
    const MIB: f64 = KIB * 1024.0;
    const GIB: f64 = MIB * 1024.0;
    let bytes = bytes as f64;
    if bytes >= GIB {
        format!("{:.1} GB", bytes / GIB)
    } else if bytes >= MIB {
        format!("{:.0} MB", bytes / MIB)
    } else if bytes >= KIB {
        format!("{:.0} KB", bytes / KIB)
    } else {
        format!("{bytes:.0} B")
    }
}
