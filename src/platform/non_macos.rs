use std::path::PathBuf;

pub fn list_applications() -> Vec<String> {
    Vec::new()
}

pub fn app_icon_path(_app_name: &str) -> Option<PathBuf> {
    None
}

pub fn preload_app_icons() {}

pub fn frontmost_app_name() -> Option<String> {
    None
}

pub fn main_display_size() -> (usize, usize) {
    (1440, 900)
}

pub fn notch_width() -> Option<u32> {
    None
}

pub fn notch_dimensions() -> Option<(f64, f64)> {
    None
}

pub fn fuzzy_match(query: &str, candidate: &str) -> Option<i32> {
    if query.is_empty() {
        return Some(0);
    }

    let query_lower = query.to_lowercase();
    let candidate_lower = candidate.to_lowercase();
    let mut score = 0i32;
    let mut qi = query_lower.chars().peekable();
    for (i, c) in candidate_lower.chars().enumerate() {
        if qi.peek() == Some(&c) {
            qi.next();
            score += 100 - i as i32;
        }
    }

    qi.peek().is_none().then_some(score)
}
