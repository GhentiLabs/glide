//! Renders the settings window shell: the sidebar, the top bar (microphone
//! picker), and dispatch to the active pane. The onboarding overlay takes over
//! the whole window until it is completed.

use gpui::prelude::*;
use gpui::{SharedString, div};
use gpui_component::button::{Button, ButtonVariants};
use gpui_component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_component::sidebar::{Sidebar, SidebarMenu, SidebarMenuItem, SidebarToggleButton};
use gpui_component::{ActiveTheme, Icon, IconName, Side, Sizable};

use super::{SettingsApp, SettingsPane};

impl SettingsApp {
    fn render_sidebar(
        &self,
        _window: &mut gpui::Window,
        cx: &mut gpui::Context<Self>,
    ) -> impl IntoElement {
        let collapsed = self.sidebar_collapsed;

        Sidebar::new(Side::Left).collapsed(collapsed).child(
            SidebarMenu::new()
                .child(
                    SidebarMenuItem::new("General")
                        .icon(Icon::new(IconName::Settings))
                        .active(self.active_pane == SettingsPane::General)
                        .on_click(cx.listener(|this, _, _window, cx| {
                            this.active_pane = SettingsPane::General;
                            cx.notify();
                        })),
                )
                .child(
                    SidebarMenuItem::new("Styles")
                        .icon(Icon::new(IconName::Palette))
                        .active(self.active_pane == SettingsPane::Styles)
                        .on_click(cx.listener(|this, _, _window, cx| {
                            this.active_pane = SettingsPane::Styles;
                            cx.notify();
                        })),
                )
                .child(
                    SidebarMenuItem::new("Providers")
                        .icon(Icon::new(IconName::Globe))
                        .active(self.active_pane == SettingsPane::Providers)
                        .on_click(cx.listener(|this, _, _window, cx| {
                            this.active_pane = SettingsPane::Providers;
                            cx.notify();
                        })),
                )
                .child(
                    SidebarMenuItem::new("Dictionary")
                        .icon(Icon::new(IconName::BookOpen))
                        .active(self.active_pane == SettingsPane::Dictionary)
                        .on_click(cx.listener(|this, _, _window, cx| {
                            this.active_pane = SettingsPane::Dictionary;
                            cx.notify();
                        })),
                ),
        )
    }

    fn render_content(
        &mut self,
        window: &mut gpui::Window,
        cx: &mut gpui::Context<Self>,
    ) -> impl IntoElement {
        let snapshot = self.shared.snapshot();

        div()
            .flex_1()
            .min_w_0()
            .overflow_hidden()
            .p_6()
            .id("content-scroll")
            .overflow_y_scroll()
            .bg(cx.theme().background)
            .child(match self.active_pane {
                SettingsPane::Providers => self
                    .render_providers_pane(window, cx, &snapshot)
                    .into_any_element(),
                SettingsPane::Styles => self.render_styles_pane(window, cx).into_any_element(),
                SettingsPane::General => self
                    .render_general_pane(window, cx, &snapshot)
                    .into_any_element(),
                SettingsPane::Dictionary => {
                    self.render_dictionary_pane(window, cx).into_any_element()
                }
            })
    }
}

impl Render for SettingsApp {
    fn render(
        &mut self,
        window: &mut gpui::Window,
        cx: &mut gpui::Context<Self>,
    ) -> impl IntoElement {
        if self.show_onboarding {
            return self
                .render_onboarding_overlay(window, cx)
                .into_any_element();
        }

        let snapshot = self.shared.snapshot();
        let mic_name = if snapshot.config.audio.device == "default" {
            "Default Microphone".to_string()
        } else {
            snapshot.config.audio.device.clone()
        };
        let devices: Vec<String> = if snapshot.input_devices.is_empty() {
            vec!["default".to_string()]
        } else {
            snapshot.input_devices.clone()
        };

        div()
            .flex()
            .size_full()
            .bg(cx.theme().background)
            .child(self.render_sidebar(window, cx))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w_0()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .px_3()
                            .py_2()
                            .border_b_1()
                            .border_color(cx.theme().border)
                            .child(
                                SidebarToggleButton::left()
                                    .collapsed(self.sidebar_collapsed)
                                    .on_click(cx.listener(|this, _, _window, cx| {
                                        this.sidebar_collapsed = !this.sidebar_collapsed;
                                        cx.notify();
                                    })),
                            )
                            .child({
                                let shared_for_menu = self.shared.clone();
                                Button::new("top-bar-mic")
                                    .label(SharedString::from(mic_name))
                                    .ghost()
                                    .small()
                                    .compact()
                                    .on_click(cx.listener(|this, _, _window, cx| {
                                        this.shared.refresh_input_devices();
                                        cx.notify();
                                    }))
                                    .dropdown_menu(move |menu, _, _| {
                                        let mut m = menu;
                                        for device in &devices {
                                            let d = device.clone();
                                            let shared = shared_for_menu.clone();
                                            m = m.item(
                                                PopupMenuItem::new(SharedString::from(d.clone()))
                                                    .on_click(move |_, _, _cx| {
                                                        let _ = shared.update_config(|config| {
                                                            config.audio.device = d.clone();
                                                        });
                                                    }),
                                            );
                                        }
                                        m
                                    })
                            }),
                    )
                    .child(self.render_content(window, cx)),
            )
            .into_any_element()
    }
}
