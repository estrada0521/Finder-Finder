fn main() {
    match finder_finder_lib::generate_csv_previews() {
        Ok(report) => println!(
            "generated={} skipped_existing={} skipped_without_csv={} failed={}",
            report.generated, report.skipped_existing, report.skipped_without_csv, report.failed
        ),
        Err(error) => {
            eprintln!("generate-csv-previews: {error}");
            std::process::exit(1);
        }
    }
}
