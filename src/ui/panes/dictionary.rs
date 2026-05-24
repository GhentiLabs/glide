use gpui::prelude::*;
use gpui::{SharedString, div};
use gpui_component::ActiveTheme;
use gpui_component::Sizable;
use gpui_component::button::{Button, ButtonVariants};
use gpui_component::input::Input;

use super::super::SettingsApp;
use super::super::helpers::*;

impl SettingsApp {
    pub(in crate::ui) fn render_dictionary_pane(
        &mut self,
        _window: &mut gpui::Window,
        cx: &mut gpui::Context<Self>,
    ) -> impl IntoElement {
        let snapshot = self.shared.snapshot();
        let mut container = div().flex().flex_col().gap_4();

        // -- Vocabulary Section --
        let mut vocab_card = settings_card(cx)
            .child(hint_row(
                "Words and phrases that help the transcription model recognize specific terms, names, and acronyms.",
                cx,
            ))
            .gap_2();

        let vocab = &snapshot.config.dictionary.vocabulary;
        if !vocab.is_empty() {
            let mut chips = div().flex().flex_wrap().gap_1().py_1();
            for (i, word) in vocab.iter().enumerate() {
                let shared = self.shared.clone();
                chips = chips.child(
                    div()
                        .id(SharedString::from(format!("vocab-{i}")))
                        .flex()
                        .items_center()
                        .gap_1()
                        .px_2()
                        .py_0p5()
                        .rounded_md()
                        .bg(cx.theme().secondary)
                        .border_1()
                        .border_color(cx.theme().border)
                        .text_xs()
                        .child(div().text_color(cx.theme().foreground).child(word.clone()))
                        .child(
                            Button::new(SharedString::from(format!("rm-vocab-{i}")))
                                .label("×")
                                .ghost()
                                .xsmall()
                                .compact()
                                .on_click(cx.listener(move |_this, _, _window, cx| {
                                    let _ = shared.update_config(|config| {
                                        if i < config.dictionary.vocabulary.len() {
                                            config.dictionary.vocabulary.remove(i);
                                        }
                                    });
                                    cx.notify();
                                })),
                        ),
                );
            }
            vocab_card = vocab_card.child(chips);
        }

        let shared_add_vocab = self.shared.clone();
        let vocab_input_entity = self.vocabulary_input.clone();
        vocab_card = vocab_card.child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(div().flex_1().child(Input::new(&self.vocabulary_input)))
                .child(
                    Button::new("add-vocab")
                        .label("Add")
                        .ghost()
                        .small()
                        .compact()
                        .on_click(cx.listener(move |_this, _, window, cx| {
                            let word = vocab_input_entity
                                .read(cx)
                                .value()
                                .to_string()
                                .trim()
                                .to_string();
                            if !word.is_empty() {
                                let _ = shared_add_vocab.update_config(|config| {
                                    config.dictionary.vocabulary.push(word);
                                });
                                vocab_input_entity.update(cx, |state, cx| {
                                    use gpui::EntityInputHandler;
                                    state.replace_text_in_range(
                                        Some(std::ops::Range {
                                            start: 0,
                                            end: state.value().len(),
                                        }),
                                        "",
                                        window,
                                        cx,
                                    );
                                });
                                cx.notify();
                            }
                        })),
                ),
        );

        container = container.child(section_block("Vocabulary", cx).child(vocab_card));

        // -- Replacements Section --
        let mut repl_card = settings_card(cx)
            .child(hint_row(
                "Auto-replace rules applied after transcription.",
                cx,
            ))
            .gap_2();

        let replacements = &snapshot.config.dictionary.replacements;
        for (i, rule) in replacements.iter().enumerate() {
            let shared = self.shared.clone();
            let cs_label = if rule.case_sensitive { " (Aa)" } else { "" };
            repl_card = repl_card.child(
                div()
                    .id(SharedString::from(format!("repl-{i}")))
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .py_1()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .text_sm()
                            .child(
                                div()
                                    .text_color(cx.theme().foreground)
                                    .child(rule.find.clone()),
                            )
                            .child(
                                div()
                                    .text_color(cx.theme().muted_foreground)
                                    .text_xs()
                                    .child("→"),
                            )
                            .child(
                                div()
                                    .text_color(cx.theme().foreground)
                                    .child(rule.replace.clone()),
                            )
                            .child(
                                div()
                                    .text_color(cx.theme().muted_foreground)
                                    .text_xs()
                                    .child(cs_label.to_string()),
                            ),
                    )
                    .child(
                        Button::new(SharedString::from(format!("rm-repl-{i}")))
                            .label("×")
                            .ghost()
                            .small()
                            .compact()
                            .on_click(cx.listener(move |_this, _, _window, cx| {
                                let _ = shared.update_config(|config| {
                                    if i < config.dictionary.replacements.len() {
                                        config.dictionary.replacements.remove(i);
                                    }
                                });
                                cx.notify();
                            })),
                    ),
            );
        }

        let shared_add_repl = self.shared.clone();
        let find_entity = self.replacement_find_input.clone();
        let replace_entity = self.replacement_replace_input.clone();
        repl_card = repl_card.child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(
                    div()
                        .flex_1()
                        .child(Input::new(&self.replacement_find_input)),
                )
                .child(
                    div()
                        .text_color(cx.theme().muted_foreground)
                        .text_xs()
                        .child("→"),
                )
                .child(
                    div()
                        .flex_1()
                        .child(Input::new(&self.replacement_replace_input)),
                )
                .child(
                    Button::new("add-repl")
                        .label("Add")
                        .ghost()
                        .small()
                        .compact()
                        .on_click(cx.listener(move |_this, _, window, cx| {
                            let find = find_entity.read(cx).value().to_string().trim().to_string();
                            let replace = replace_entity
                                .read(cx)
                                .value()
                                .to_string()
                                .trim()
                                .to_string();
                            if !find.is_empty() {
                                let _ = shared_add_repl.update_config(|config| {
                                    config.dictionary.replacements.push(
                                        crate::config::ReplacementRule {
                                            find,
                                            replace,
                                            case_sensitive: false,
                                        },
                                    );
                                });
                                find_entity.update(cx, |state, cx| {
                                    use gpui::EntityInputHandler;
                                    state.replace_text_in_range(
                                        Some(std::ops::Range {
                                            start: 0,
                                            end: state.value().len(),
                                        }),
                                        "",
                                        window,
                                        cx,
                                    );
                                });
                                replace_entity.update(cx, |state, cx| {
                                    use gpui::EntityInputHandler;
                                    state.replace_text_in_range(
                                        Some(std::ops::Range {
                                            start: 0,
                                            end: state.value().len(),
                                        }),
                                        "",
                                        window,
                                        cx,
                                    );
                                });
                                cx.notify();
                            }
                        })),
                ),
        );

        container = container.child(section_block("Replacements", cx).child(repl_card));

        container
    }
}
