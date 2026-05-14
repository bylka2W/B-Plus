use rand::Rng;

/// 3-layer neural network: 21→16→1 (port of C# NeuralPredictor)
pub struct NeuralPredictor {
    w1: Vec<Vec<f64>>,  // [16][21]
    b1: Vec<f64>,       // [16]
    w2: Vec<Vec<f64>>,  // [1][16]
    b2: Vec<f64>,       // [1]
    learning_rate: f64,
}

impl NeuralPredictor {
    pub fn new(input_size: usize, hidden_size: usize) -> Self {
        let mut rng = rand::thread_rng();
        let w1 = (0..hidden_size).map(|_|
            (0..input_size).map(|_| rng.gen_range(-0.1..0.1)).collect()
        ).collect();
        let b1 = (0..hidden_size).map(|_| rng.gen_range(-0.05..0.05)).collect();
        let w2 = (0..1).map(|_|
            (0..hidden_size).map(|_| rng.gen_range(-0.1..0.1)).collect()
        ).collect();
        let b2 = vec![rng.gen_range(-0.05..0.05)];

        Self { w1, b1, w2, b2, learning_rate: 0.01 }
    }

    pub fn predict(&self, input: &[f64]) -> f64 {
        let hidden = self.forward_hidden(input);
        let output = self.forward_output(&hidden);
        output.max(0.0).min(6.0)
    }

    pub fn train(&mut self, input: &[f64], target: f64) -> f64 {
        let target_norm = (target / 6.0).clamp(0.0, 1.0);

        // Forward
        let hidden = self.forward_hidden(input);
        let output = self.forward_output(&hidden);
        let error = output - target_norm;

        // Backward — output layer
        let d_output = error;
        for j in 0..self.w2[0].len() {
            self.w2[0][j] -= self.learning_rate * d_output * hidden[j];
        }
        self.b2[0] -= self.learning_rate * d_output;

        // Backward — hidden layer
        for i in 0..self.w1.len() {
            let dh = d_output * self.w2[0][i] * relu_deriv(hidden[i]);
            for j in 0..self.w1[i].len() {
                self.w1[i][j] -= self.learning_rate * dh * input[j];
            }
            self.b1[i] -= self.learning_rate * dh;
        }

        error.abs()
    }

    fn forward_hidden(&self, input: &[f64]) -> Vec<f64> {
        self.w1.iter().enumerate().map(|(i, row)| {
            let sum: f64 = row.iter().zip(input.iter()).map(|(w, x)| w * x).sum();
            relu(sum + self.b1[i])
        }).collect()
    }

    fn forward_output(&self, hidden: &[f64]) -> f64 {
        let sum: f64 = self.w2[0].iter().zip(hidden.iter()).map(|(w, h)| w * h).sum();
        sigmoid(sum + self.b2[0])
    }
}

fn relu(x: f64) -> f64 { x.max(0.0) }
fn relu_deriv(x: f64) -> f64 { if x > 0.0 { 1.0 } else { 0.0 } }
fn sigmoid(x: f64) -> f64 { 1.0 / (1.0 + (-x).exp()) }
