namespace BPlusTranspiler.AI;

public struct SchedulerState
{
    public double Ipc;
    public double FreqMHz;
    public double TempC;
    public double PowerW;
    public double CoreUtil;
    public double Headroom;
    public double RamBW;
    public double L3MissRate;
    public double BranchMispredictRate;
}

public struct SchedulerAction
{
    public int TargetCores;
    public double TargetFreqMHz;
    public PowerProfile Profile;
}

public enum PowerProfile
{
    MaxPerf,
    Turbo,
    Efficient,
    PowerSave
}

public class NeuroScheduler
{
    private readonly int _stateDim = 11;
    private readonly int _actionDim = 4;
    private readonly int _hiddenSize;
    private readonly int _historyLen = 5;

    private double[,] _lstmWf, _lstmWi, _lstmWo, _lstmWc;
    private double[] _lstmBf, _lstmBi, _lstmBo, _lstmBc;
    private double[,] _qTable;
    private double _gamma = 0.9;
    private double _epsilon = 0.1;
    private double _lr = 0.01;
    private readonly double _epsilonDecay = 0.995;
    private readonly double _minEpsilon = 0.01;
    private readonly Random _rng = new(42);

    private readonly List<(SchedulerState s, int a, double r, SchedulerState s2, bool done)> _replayBuffer = new();
    private const int ReplayCapacity = 1000;
    private const int BatchSize = 32;

    public NeuroScheduler(int hiddenSize = 16)
    {
        _hiddenSize = hiddenSize;
        int h = hiddenSize;
        int d = _stateDim;

        _lstmWf = new double[d, h]; _lstmWi = new double[d, h];
        _lstmWo = new double[d, h]; _lstmWc = new double[d, h];
        _lstmBf = new double[h]; _lstmBi = new double[h];
        _lstmBo = new double[h]; _lstmBc = new double[h];
        _qTable = new double[_actionDim, h];

        double scale = Math.Sqrt(2.0 / (d + h));
        for (int i = 0; i < d; i++)
            for (int j = 0; j < h; j++)
            {
                _lstmWf[i, j] = Gaussian() * scale;
                _lstmWi[i, j] = Gaussian() * scale;
                _lstmWo[i, j] = Gaussian() * scale;
                _lstmWc[i, j] = Gaussian() * scale;
            }

        scale = Math.Sqrt(2.0 / (h + _actionDim));
        for (int a = 0; a < _actionDim; a++)
            for (int j = 0; j < h; j++)
                _qTable[a, j] = Gaussian() * scale;
    }

    private double Gaussian()
    {
        double u1 = 1.0 - _rng.NextDouble();
        double u2 = 1.0 - _rng.NextDouble();
        return Math.Sqrt(-2.0 * Math.Log(u1)) * Math.Sin(2.0 * Math.PI * u2);
    }

    public SchedulerAction SelectAction(SchedulerState s, bool training = true)
    {
        if (training && _rng.NextDouble() < _epsilon)
        {
            var profiles = new PowerProfile[] { PowerProfile.MaxPerf, PowerProfile.Turbo, PowerProfile.Efficient, PowerProfile.PowerSave };
            int idx = _rng.Next(4);
            return new SchedulerAction
            {
                TargetCores = idx switch { 0 => 8, 1 => 4, 2 => 2, _ => 1 },
                TargetFreqMHz = idx switch { 0 => 5000, 1 => 4000, 2 => 2500, _ => 1200 },
                Profile = profiles[idx]
            };
        }

        var features = StateToFeatures(s);
        double[] hidden = new double[_hiddenSize];
        for (int j = 0; j < _hiddenSize; j++)
        {
            double sumF = _lstmBf[j], sumI = _lstmBi[j], sumO = _lstmBo[j], sumC = _lstmBc[j];
            for (int i = 0; i < _stateDim; i++)
            {
                sumF += _lstmWf[i, j] * features[i];
                sumI += _lstmWi[i, j] * features[i];
                sumO += _lstmWo[i, j] * features[i];
                sumC += _lstmWc[i, j] * features[i];
            }
            double f = Sigmoid(sumF);
            double input = Sigmoid(sumI);
            double o = Sigmoid(sumO);
            double cell = Tanh(sumC);
            hidden[j] = o * Tanh(f * cell + input * cell);
        }

        int bestAction = 0;
        double bestQ = double.MinValue;
        for (int a = 0; a < _actionDim; a++)
        {
            double q = 0;
            for (int j = 0; j < _hiddenSize; j++)
                q += _qTable[a, j] * hidden[j];
            if (q > bestQ) { bestQ = q; bestAction = a; }
        }

        var profiles2 = new PowerProfile[] { PowerProfile.MaxPerf, PowerProfile.Turbo, PowerProfile.Efficient, PowerProfile.PowerSave };
        return new SchedulerAction
        {
            TargetCores = bestAction switch { 0 => 8, 1 => 4, 2 => 2, _ => 1 },
            TargetFreqMHz = bestAction switch { 0 => 5000, 1 => 4000, 2 => 2500, _ => 1200 },
            Profile = profiles2[bestAction]
        };
    }

    public void StoreTransition(SchedulerState s, int a, double r, SchedulerState s2, bool done)
    {
        _replayBuffer.Add((s, a, r, s2, done));
        if (_replayBuffer.Count > ReplayCapacity)
            _replayBuffer.RemoveAt(0);
    }

    public void Train()
    {
        if (_replayBuffer.Count < BatchSize) return;

        for (int epoch = 0; epoch < 10; epoch++)
        {
            var batch = _replayBuffer.OrderBy(_ => _rng.Next()).Take(BatchSize).ToList();
            double totalLoss = 0;

            foreach (var (s, a, r, s2, done) in batch)
            {
                double[] f = StateToFeatures(s);
                double[] f2 = StateToFeatures(s2);

                double[] h = LstmForward(f);
                double[] h2 = LstmForward(f2);

                double target = done ? r : r + _gamma * MaxQ(h2);

                double current = 0;
                for (int j = 0; j < _hiddenSize; j++)
                    current += _qTable[a, j] * h[j];

                double error = target - current;
                totalLoss += error * error;

                for (int j = 0; j < _hiddenSize; j++)
                    _qTable[a, j] += _lr * error * h[j];
            }

            _epsilon = Math.Max(_minEpsilon, _epsilon * _epsilonDecay);
        }
    }

    private double[] StateToFeatures(SchedulerState s)
    {
        return new double[] {
            s.Ipc, s.FreqMHz / 5000.0, s.TempC / 100.0,
            s.PowerW / 200.0, s.CoreUtil / 100.0, s.Headroom,
            s.RamBW / 50.0, s.L3MissRate, s.BranchMispredictRate,
            Math.Sin(s.FreqMHz), Math.Cos(s.FreqMHz)
        };
    }

    private double[] LstmForward(double[] features)
    {
        double[] hidden = new double[_hiddenSize];
        double[] cell = new double[_hiddenSize];
        for (int j = 0; j < _hiddenSize; j++)
        {
            double sumF = _lstmBf[j], sumI = _lstmBi[j], sumO = _lstmBo[j], sumC = _lstmBc[j];
            for (int i = 0; i < _stateDim; i++)
            {
                sumF += _lstmWf[i, j] * features[i];
                sumI += _lstmWi[i, j] * features[i];
                sumO += _lstmWo[i, j] * features[i];
                sumC += _lstmWc[i, j] * features[i];
            }
            double f = Sigmoid(sumF);
            double inp = Sigmoid(sumI);
            double o = Sigmoid(sumO);
            double c = Tanh(sumC);
            cell[j] = f * cell[j] + inp * c;
            hidden[j] = o * Tanh(cell[j]);
        }
        return hidden;
    }

    private double MaxQ(double[] hidden)
    {
        double maxQ = double.MinValue;
        for (int a = 0; a < _actionDim; a++)
        {
            double q = 0;
            for (int j = 0; j < _hiddenSize; j++)
                q += _qTable[a, j] * hidden[j];
            if (q > maxQ) maxQ = q;
        }
        return maxQ;
    }

    private static double Sigmoid(double x) => 1.0 / (1.0 + Math.Exp(-x));
    private static double Tanh(double x) => Math.Tanh(x);

    public double ComputeReward(SchedulerState before, SchedulerState after, SchedulerAction action)
    {
        double ipcGain = after.Ipc - before.Ipc;
        double freqUtil = after.FreqMHz / action.TargetFreqMHz;
        double tempPenalty = Math.Max(0, after.TempC - 80) / 20.0;
        double powerPenalty = after.PowerW > 100 ? (after.PowerW - 100) / 100.0 : 0;
        return ipcGain * 10 + freqUtil * 5 - tempPenalty * 3 - powerPenalty * 2;
    }

    public string GenerateReport()
    {
        return $"""
╔══════════════════════════════════════════════╗
║           NEURO SCHEDULER REPORT            ║
╚══════════════════════════════════════════════╝
State dim:  {_stateDim}
Action dim: {_actionDim}
Hidden:     {_hiddenSize}
History:    {_historyLen}
Gamma:      {_gamma:F3}
Epsilon:    {_epsilon:F4}
LR:         {_lr}
Buffer:     {_replayBuffer.Count}/{ReplayCapacity}
""";
    }
}
