use crate::ast::nodes::*;
use std::collections::HashMap;

pub struct IlpAnalyzer;

impl IlpAnalyzer {
    /// Analyze instruction-level parallelism: detect dependency chains and estimate cycles.
    pub fn analyze(state: &StateDefNode) -> IlpReport {
        let mut chains = Vec::new();
        let visited = &mut Vec::new();

        for action in &state.actions {
            let deps = parse_deps(&action.body);
            for (var, depends_on) in &deps {
                if visited.contains(var) { continue; }
                visited.push(var.clone());
                let mut chain_len = 1;
                let mut cur = var.clone();
                let mut last_was_load = is_load(&action.body, &cur);
                while let Some(parent) = deps.get(&cur) {
                    chain_len += 1;
                    let this_is_load = is_load(&action.body, parent);
                    if this_is_load && last_was_load {
                        chain_len += 1; // load→load stall penalty
                    }
                    last_was_load = this_is_load;
                    cur = parent.clone();
                    if visited.contains(&cur) { break; }
                    visited.push(cur.clone());
                }
                if chain_len > 1 {
                    chains.push(chain_len);
                }
            }
        }

        let max_chain = chains.iter().copied().max().unwrap_or(0);
        let avg_chain = if chains.is_empty() { 0.0 } else {
            chains.iter().sum::<u32>() as f64 / chains.len() as f64
        };

        // Estimate available ILP
        let ideal_ipc = if max_chain == 0 { 4.0 } else {
            (4.0f64).min(1.0 + 3.0 * (avg_chain / (avg_chain + 1.0)))
        };

        IlpReport {
            chain_count: chains.len() as u32,
            max_chain_length: max_chain,
            avg_chain_length: avg_chain,
            estimated_ipc: ideal_ipc,
            warnings: if max_chain > 8 {
                vec!["Long dependency chain detected — consider loop unrolling".into()]
            } else { Vec::new() },
        }
    }
}

#[derive(Debug, Clone)]
pub struct IlpReport {
    pub chain_count: u32,
    pub max_chain_length: u32,
    pub avg_chain_length: f64,
    pub estimated_ipc: f64,
    pub warnings: Vec<String>,
}

fn parse_deps(body: &str) -> HashMap<String, String> {
    let mut deps = HashMap::new();
    let tokens: Vec<&str> = body.split(|c: char| !c.is_alphanumeric() && c != '=')
        .filter(|s| !s.is_empty()).collect();
    for w in tokens.windows(3) {
        if w[1] == "=" {
            deps.insert(w[2].to_string(), w[0].to_string());
        }
    }
    deps
}

fn is_load(body: &str, var: &str) -> bool {
    body.contains(&format!("load({})", var)) || body.contains(&format!("ld.{}", var))
        || body.contains(&format!("*{}", var))
}
