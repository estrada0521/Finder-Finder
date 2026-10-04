use finder_finder_lib::database::{resolve_root, Database};
use serde_json::{json, Value};

const HELP: &str = "finder-finder [--db-root PATH] [--json] COMMAND\n\nCommands:\n  context\n  list [--category NAME] [--query TEXT] [--limit N]\n  show RECORD\n  links RECORD... [--direction out|in|both] [--depth N]\n  related RECORD...\n\nRECORD: ID, record directory, or metadata.json path.\nlinks defaults to outgoing direct references. related uses the GUI's\nbidirectional 3-hop walk, excluding returns to departed categories.\nRead-only. JSON stdout includes schema_version, db_root and diagnostics.\nExit codes: 0 success, 1 data/config error or partial result, 2 usage error.";
fn run(args: &[String]) -> Result<(Value, bool), (i32, String)> {
    let mut root = None;
    let mut category = None;
    let mut query = None;
    let mut limit = None;
    let mut direction = "out".to_owned();
    let mut depth = 1;
    let mut positional = vec![];
    let mut direction_set = false;
    let mut depth_set = false;
    let mut options = true;
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        if options && arg == "--" {
            options = false;
            i += 1;
            continue;
        }
        if options && arg == "--json" {
            i += 1;
            continue;
        }
        if options && arg.starts_with('-') {
            if ![
                "--db-root",
                "--category",
                "--query",
                "--limit",
                "--direction",
                "--depth",
            ]
            .contains(&arg.as_str())
            {
                return Err((2, format!("unknown option: {arg}")));
            }
            i += 1;
            let value = args
                .get(i)
                .ok_or((2, format!("missing value for {arg}")))?
                .clone();
            match arg.as_str() {
                "--db-root" => root = Some(value),
                "--category" => category = Some(value),
                "--query" => query = Some(value),
                "--limit" => {
                    limit = Some(
                        value
                            .parse::<usize>()
                            .map_err(|_| (2, "invalid limit".into()))?,
                    )
                }
                "--direction" => {
                    direction = value;
                    direction_set = true;
                }
                "--depth" => {
                    depth = value
                        .parse::<usize>()
                        .map_err(|_| (2, "invalid depth".into()))?;
                    depth_set = true;
                }
                _ => unreachable!(),
            }
        } else {
            positional.push(arg.clone());
        }
        i += 1;
    }
    let command = positional
        .first()
        .ok_or((2, "command required; use --help".into()))?;
    if !["context", "list", "show", "links", "related"].contains(&command.as_str()) {
        return Err((2, format!("unknown command: {command}")));
    }
    if command != "list" && (category.is_some() || query.is_some() || limit.is_some()) {
        return Err((2, "list options require list".into()));
    }
    if command != "links" && (direction_set || depth_set) {
        return Err((2, "direction/depth options require links".into()));
    }
    if !["out", "in", "both"].contains(&direction.as_str()) {
        return Err((2, "direction must be out, in or both".into()));
    }
    let inputs = &positional[1..];
    if ((command == "context" || command == "list") && !inputs.is_empty())
        || (command == "show" && inputs.len() != 1)
        || ((command == "links" || command == "related") && inputs.is_empty())
    {
        return Err((2, "invalid number of record arguments".into()));
    }
    let db = Database::read(resolve_root(root).map_err(|e| (1, e))?).map_err(|e| (1, e))?;
    let result = match command.as_str() {
        "context" => {
            let mut categories = std::collections::BTreeSet::new();
            for r in db.records.values() {
                if let Some(c) = r["category"].as_str() {
                    categories.insert(c);
                }
            }
            json!({"categories":categories,"record_count":db.records.len()})
        }
        "list" => {
            let mut records: Vec<_> = db
                .records
                .values()
                .filter(|r| {
                    category
                        .as_ref()
                        .is_none_or(|c| r["category"].as_str() == Some(c))
                        && query.as_ref().is_none_or(|q| {
                            format!(
                                "{} {}",
                                r["id"].as_str().unwrap_or(""),
                                r["display_name"].as_str().unwrap_or("")
                            )
                            .to_lowercase()
                            .contains(&q.to_lowercase())
                        })
                })
                .cloned()
                .collect();
            let total = records.len();
            if let Some(n) = limit {
                records.truncate(n);
            }
            json!({"total":total,"records":records})
        }
        "show" => {
            let id = db.resolve(&inputs[0]).map_err(|e| (1, e))?;
            json!({"record":db.records[&id]})
        }
        _ => {
            let mut seeds = vec![];
            for input in inputs {
                let id = db.resolve(input).map_err(|e| (1, e))?;
                if !seeds.contains(&id) {
                    seeds.push(id);
                }
            }
            db.walk(
                &seeds,
                if command == "related" {
                    "both"
                } else {
                    &direction
                },
                depth,
                command == "related",
            )
        }
    };
    let partial = !db.diagnostics.is_empty();
    Ok((
        json!({"schema_version":1,"db_root":db.root,"command":command,"result":result,"diagnostics":db.diagnostics}),
        partial,
    ))
}
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let json_output = args.iter().any(|s| s == "--json");
    if args.iter().any(|s| s == "--help" || s == "-h") {
        println!("{HELP}");
        return;
    }
    if args == ["--version"] {
        println!("finder-finder {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    match run(&args) {
        Ok((v, partial)) => {
            if json_output {
                println!("{}", serde_json::to_string_pretty(&v).unwrap());
            } else {
                print_text(&v);
            }
            if partial {
                eprintln!("finder-finder: partial result; inspect diagnostics");
                std::process::exit(1);
            }
        }
        Err((code, message)) => {
            if json_output {
                println!(
                    "{}",
                    json!({"schema_version":1,"error":{"message":message,"exit_code":code}})
                );
            }
            eprintln!("finder-finder: {message}");
            std::process::exit(code);
        }
    }
}
fn print_text(v: &Value) {
    let r = &v["result"];
    if let Some(record) = r.get("record") {
        println!("{}", serde_json::to_string_pretty(record).unwrap());
    } else if let Some(records) = r["records"].as_array() {
        for record in records {
            let entry = record.get("record").unwrap_or(record);
            println!(
                "{}\t{}\t{}{}",
                record["id"].as_str().unwrap_or(""),
                entry["category"].as_str().unwrap_or(""),
                entry["display_name"].as_str().unwrap_or("[missing]"),
                record
                    .get("distance")
                    .map(|d| format!("\t{d} hops"))
                    .unwrap_or_default()
            );
        }
        if let Some(edges) = r["edges"].as_array() {
            for edge in edges {
                println!(
                    "{} -> {}\t{}",
                    edge["from"].as_str().unwrap(),
                    edge["to"].as_str().unwrap(),
                    edge["link"]
                );
            }
        }
    } else {
        println!("{}", serde_json::to_string_pretty(r).unwrap());
    }
    if let Some(ds) = v["diagnostics"].as_array() {
        for d in ds {
            eprintln!("diagnostic: {d}");
        }
    }
}
