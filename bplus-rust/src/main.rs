mod frontend;
mod ast;
mod optimizer;
mod codegen;
mod ai;

use clap::Parser as ClapParser;
use crate::frontend::parser::Parser;
use crate::optimizer::microarch_profile::Profiles;
use crate::optimizer::register_alloc::RegisterAllocator;
use crate::optimizer::data_packer::DataPacker;
use crate::optimizer::hidden_buffer_optimizer::HiddenBufferOptimizer;
use crate::optimizer::ilp_analyzer::IlpAnalyzer;
use crate::optimizer::roofline_analyzer::RooflineAnalyzer;
use crate::optimizer::store_forward_guard::StoreForwardGuard;
use crate::optimizer::auto_tuner::AutoTuner;
use crate::ai::neural_predictor::NeuralPredictor;
use crate::ai::data_collector::DataCollector;
use crate::codegen::llvm_gen_metal::LlvmGenMetal;
use std::fs;

/// B+ v3.0.4L BETA — state machine compiler with Metal Stack + AI optimizer
#[derive(ClapParser, Debug)]
#[clap(name = "bplus", version = "3.0.4", about = "B+ state machine compiler")]
struct Cli {
    /// Input .bp file
    #[clap(short, long)]
    input: Option<String>,

    /// Output file (default: stdout)
    #[clap(short, long)]
    output: Option<String>,

    /// Target microarchitecture (intel_adl, intel_skx, intel_icx, intel_gni, amd_zen4, amd_zen3, arm_neoverse, generic)
    #[clap(long)]
    muarch: Option<String>,

    /// Analyze instruction-level parallelism
    #[clap(long)]
    ilp: bool,

    /// Enable store-forwarding hazard detection
    #[clap(long)]
    store_fwd: bool,

    /// Auto-tune with real perf counters
    #[clap(long)]
    auto_tune: bool,

    /// Roofline analysis
    #[clap(long)]
    roofline: bool,

    /// NUMA node binding
    #[clap(long)]
    numa: Option<u32>,

    /// Emit LLVM IR
    #[clap(long)]
    emit_llvm: bool,

    /// Verbose output
    #[clap(short, long)]
    verbose: bool,
}

fn main() {
    let cli = Cli::parse();

    // Determine profile
    let profile_name = cli.muarch.as_deref().unwrap_or("generic");
    let profile = Profiles::get(profile_name);
    if cli.verbose {
        eprintln!("µarch: {} (LSD={}, LFB={}, ROB={})",
            profile.name, profile.lsd_size, profile.lfb_entries, profile.rob_size);
    }

    // Read input
    let input = if let Some(path) = &cli.input {
        fs::read_to_string(path).unwrap_or_else(|e| {
            eprintln!("Error reading {}: {}", path, e);
            std::process::exit(1);
        })
    } else {
        // Read from stdin
        let mut buf = String::new();
        std::io::Read::read_to_string(&mut std::io::stdin(), &mut buf).unwrap();
        buf
    };

    // Parse
    let mut parser = Parser::new(&input);
    let program = match parser.parse() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Parse error: {}", e);
            std::process::exit(1);
        }
    };

    if cli.verbose {
        eprintln!("Parsed {} state(s), {} kernel(s)", program.states.len(), program.kernels.len());
    }

    // Optimize
    for state in &program.states {
        // Register allocation with dep graph
        let regs = RegisterAllocator::pack_vars(state, &profile);
        if cli.verbose {
            eprintln!("  state {}: {:?}", state.name, regs);
        }

        // ILP analysis
        if cli.ilp {
            let ilp = IlpAnalyzer::analyze(state);
            eprintln!("  ILP: chains={}, max_len={}, est_IPC={:.2}",
                ilp.chain_count, ilp.max_chain_length, ilp.estimated_ipc);
            for w in &ilp.warnings {
                eprintln!("  ⚠ {}", w);
            }
        }

        // Hidden buffer analysis
        let mem_streams = state.variables.len() as u32;
        let buf = HiddenBufferOptimizer::analyze(
            &profile, 8, mem_streams, 64, 4, 8
        );
        if cli.verbose {
            for w in &buf.warnings {
                eprintln!("  ⚠ {}", w);
            }
        }

        // Store-forward detection
        if cli.store_fwd {
            let sf = StoreForwardGuard::detect(state, &profile);
            if !sf.safe {
                eprintln!("  Store-forward hazards: {}", sf.hazards.len());
                for w in &sf.warnings {
                    eprintln!("  ⚠ {}", w);
                }
            }
        }

        // Data packing
        let packs = DataPacker::pack_fields(&state.variables);
        if cli.verbose && packs.len() > 1 {
            eprintln!("  Packed {} cache-line groups", packs.len());
        }

        // Roofline
        if cli.roofline {
            let flops = state.actions.len() as u64 * 8;
            let bytes = state.variables.len() as u64 * 8;
            let rl = RooflineAnalyzer::analyze(flops, bytes, 2000.0, 100.0);
            eprintln!("  Roofline: AI={:.2}, bound={}, perf={:.1} GFLOPs",
                rl.arithmetic_intensity,
                if rl.is_compute_bound { "compute" } else { "memory" },
                rl.estimated_performance);
        }
    }

    // AI auto-tune
    if cli.auto_tune {
        let mut predictor = NeuralPredictor::new(20, 16);
        let mut collector = DataCollector::new();
        eprintln!("Running auto-tune...");
        let history = AutoTuner::tune(&mut predictor, &mut collector, 5, 2000);
        if let Some(last) = history.last() {
            eprintln!("Auto-tune done: predicted IPC={:.3}, measured={:.3}",
                last.predicted_ipc, last.measured_ipc);
        }
    }

    // Generate LLVM IR
    let ir = LlvmGenMetal::generate(&program, &profile);

    // Output
    if let Some(path) = &cli.output {
        fs::write(path, &ir).unwrap_or_else(|e| {
            eprintln!("Error writing {}: {}", path, e);
            std::process::exit(1);
        });
        if cli.verbose {
            eprintln!("Wrote {}", path);
        }
    } else {
        println!("{}", ir);
    }
}
