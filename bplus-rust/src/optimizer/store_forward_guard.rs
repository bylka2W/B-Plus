use crate::ast::nodes::*;
use crate::optimizer::microarch_profile::MicroArchProfile;

pub struct StoreForwardGuard;

#[derive(Debug, Clone)]
pub struct StoreForwardReport {
    pub hazards: Vec<StoreForwardHazard>,
    pub safe: bool,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct StoreForwardHazard {
    pub store_var: String,
    pub load_var: String,
    pub offset: i32,
    pub size_mismatch: bool,
}

impl StoreForwardGuard {
    /// Detect store-forwarding hazards: store→load to overlapping addresses
    /// where the store hasn't completed before the load issues.
    pub fn detect(state: &StateDefNode, profile: &MicroArchProfile) -> StoreForwardReport {
        let mut hazards = Vec::new();
        let mut warnings = Vec::new();

        // Collect stores and loads from actions
        let mut stores = Vec::new();
        let mut loads = Vec::new();

        for action in &state.actions {
            let body = action.body.to_lowercase();
            // Detect stores: var = ...
            for token in body.split(|c: char| !c.is_alphanumeric() && c != '[' && c != ']' && c != '+') {
                let t = token.trim();
                if is_store(&body, t) { stores.push(t.to_string()); }
                if is_load(&body, t) { loads.push(t.to_string()); }
            }
        }

        for store in &stores {
            for load in &loads {
                if store == load || (load.contains(store) && !load.contains("->")) {
                    hazards.push(StoreForwardHazard {
                        store_var: store.clone(),
                        load_var: load.clone(),
                        offset: 0,
                        size_mismatch: false,
                    });
                }
            }
        }

        if !hazards.is_empty() {
            warnings.push(format!(
                "{} store-forwarding hazard(s) detected — add nop or align stores",
                hazards.len()
            ));
        }

        if stores.len() > profile.store_buffer as usize {
            warnings.push("Store buffer may overflow — batch stores".into());
        }

        StoreForwardReport {
            safe: hazards.is_empty(),
            hazards,
            warnings,
        }
    }
}

fn is_store(body: &str, var: &str) -> bool {
    body.contains(&format!("{} =", var)) && !body.contains(&format!("{} ==", var))
}

fn is_load(body: &str, var: &str) -> bool {
    body.contains(&format!(" = {}", var)) || body.contains(&format!("+ {}", var))
        || body.contains(&format!("({}", var))
}
