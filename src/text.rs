//! Text scanning helpers shared across pipeline stages.

use std::ops::Range;

/// Find the first case-insensitive occurrence of `needle` in `haystack`,
/// returning the matched byte range in `haystack` itself. Returns `None` for
/// an empty needle.
///
/// Chars are compared via their `to_lowercase()` expansions, so offsets never
/// come from a differently-sized lowercased copy of the haystack (which would
/// panic or corrupt slices for chars like 'İ' whose lowercase form has a
/// different byte length). This is not full Unicode case folding: 'İ' matches
/// 'İ' but not its lowercase expansion "i\u{307}", which is acceptable here.
pub(crate) fn find_ignore_case(haystack: &str, needle: &str) -> Option<Range<usize>> {
    if needle.is_empty() {
        return None;
    }
    haystack.char_indices().find_map(|(start, _)| {
        match_len_ignore_case(&haystack[start..], needle).map(|len| start..start + len)
    })
}

fn match_len_ignore_case(haystack: &str, needle: &str) -> Option<usize> {
    let mut haystack_chars = haystack.chars();
    let mut len = 0;
    for needle_char in needle.chars() {
        let haystack_char = haystack_chars.next()?;
        if !haystack_char.to_lowercase().eq(needle_char.to_lowercase()) {
            return None;
        }
        len += haystack_char.len_utf8();
    }
    Some(len)
}

#[cfg(test)]
mod tests {
    use super::find_ignore_case;

    #[test]
    fn returns_byte_range_in_original_string() {
        assert_eq!(find_ignore_case("İabc", "AB"), Some(2..4));
    }

    #[test]
    fn empty_needle_returns_none() {
        assert_eq!(find_ignore_case("abc", ""), None);
    }

    #[test]
    fn matches_multibyte_char_against_itself_ignoring_surrounding_case() {
        assert_eq!(find_ignore_case("say İSTANBUL", "İstanbul"), Some(4..13));
    }

    #[test]
    fn does_not_match_multibyte_char_against_its_lowercase_expansion() {
        assert_eq!(find_ignore_case("İ", "i\u{307}"), None);
        assert_eq!(find_ignore_case("i\u{307}", "İ"), None);
    }
}
