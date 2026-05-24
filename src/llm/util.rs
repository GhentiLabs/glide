/// Remove `<think>...</think>` blocks from LLM output.
pub(crate) fn strip_think_tags(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut remaining = text;
    while let Some(start) = remaining.to_lowercase().find("<think") {
        result.push_str(&remaining[..start]);
        if let Some(end) = remaining[start..].to_lowercase().find("</think") {
            let close_end = remaining[start + end..]
                .find('>')
                .map(|i| start + end + i + 1)
                .unwrap_or(remaining.len());
            remaining = &remaining[close_end..];
        } else {
            remaining = "";
        }
    }
    result.push_str(remaining);
    result.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::strip_think_tags;

    #[test]
    fn removes_reasoning_block() {
        assert_eq!(strip_think_tags("<think>reasoning</think>Hello"), "Hello");
    }

    #[test]
    fn removes_inline_reasoning_block() {
        assert_eq!(
            strip_think_tags("Hi <think>reasoning</think>there"),
            "Hi there"
        );
    }

    #[test]
    fn removes_case_insensitive_reasoning_block() {
        assert_eq!(strip_think_tags("<THINK>reasoning</ThInK> Hello"), "Hello");
    }

    #[test]
    fn removes_unclosed_reasoning_block() {
        assert_eq!(strip_think_tags("Answer<think>hidden"), "Answer");
    }
}
