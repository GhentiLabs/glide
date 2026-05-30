fn main() {
    if let Err(error) = glide_benchmark::run_cli() {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
}
