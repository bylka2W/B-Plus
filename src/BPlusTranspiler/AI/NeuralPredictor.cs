using System.Buffers;

namespace BPlusTranspiler.AI;

public class NeuralPredictor
{
    private int _inputSize;
    private int _hiddenSize;

    private double[,] _w1;
    private double[] _b1;
    private double[] _w2;
    private double _b2;

    // Batch norm (hidden layer)
    private double[] _bnGamma;
    private double[] _bnBeta;
    private double[] _bnRunningMean;
    private double[] _bnRunningVar;
    private const double BnMomentum = 0.9;

    // Training state
    private double _baseLearningRate = 0.001;
    private double _learningRate = 0.001;
    private double _l2Lambda = 0.001;
    private const double GradientClipNorm = 0.5;
    private const double DropoutRate = 0.2;
    private static readonly int Patience = 50;
    private const double MinDelta = 1e-6;

    // Metrics
    public double TrainR2 { get; private set; }
    public double ValR2 { get; private set; }
    public double TrainRmse { get; private set; }
    public double ValRmse { get; private set; }

    // Cached arrays (ArrayPool)
    private double[] _hiddenPool;
    private readonly Random _rand = new(42);

    public NeuralPredictor(int inputSize, int hiddenSize = 16)
    {
        _inputSize = inputSize;
        _hiddenSize = hiddenSize;
        _hiddenPool = ArrayPool<double>.Shared.Rent(hiddenSize);

        int h = hiddenSize;

        _w1 = new double[_inputSize, h];
        _b1 = new double[h];
        _w2 = new double[h];

        // Xavier initialization (Glorot) for tanh/linear hidden
        double w1Scale = Math.Sqrt(2.0 / (_inputSize + h));
        double w2Scale = Math.Sqrt(2.0 / (h + 1));

        for (int i = 0; i < _inputSize; i++)
            for (int j = 0; j < h; j++)
                _w1[i, j] = (RandGaussian()) * w1Scale;

        for (int j = 0; j < h; j++)
            _b1[j] = 0;

        for (int j = 0; j < h; j++)
            _w2[j] = (RandGaussian()) * w2Scale;

        _b2 = 0;

        // Batch norm
        _bnGamma = new double[h];
        _bnBeta = new double[h];
        _bnRunningMean = new double[h];
        _bnRunningVar = new double[h];
        for (int j = 0; j < h; j++)
        {
            _bnGamma[j] = 1.0;
            _bnBeta[j] = 0.0;
            _bnRunningMean[j] = 0.0;
            _bnRunningVar[j] = 1.0;
        }
    }

    // Box-Muller transform for Xavier init
    private double RandGaussian()
    {
        double u1 = 1.0 - _rand.NextDouble();
        double u2 = 1.0 - _rand.NextDouble();
        return Math.Sqrt(-2.0 * Math.Log(u1)) * Math.Sin(2.0 * Math.PI * u2);
    }

    /// <summary>
    /// Activation: ReLU (hidden), Linear (output).
    /// Xavier-initialized weights, batch norm before activation.
    /// </summary>
    public double Predict(double[] input)
    {
        double[] hidden = _hiddenPool;
        for (int j = 0; j < _hiddenSize; j++)
        {
            double sum = _b1[j];
            for (int i = 0; i < _inputSize; i++)
                sum += _w1[i, j] * input[i];
            // Batch norm (inference: use running stats)
            sum = (sum - _bnRunningMean[j]) / Math.Sqrt(_bnRunningVar[j] + 1e-8);
            sum = _bnGamma[j] * sum + _bnBeta[j];
            hidden[j] = Math.Max(0, sum); // ReLU
        }

        double output = _b2;
        for (int j = 0; j < _hiddenSize; j++)
            output += _w2[j] * hidden[j];

        return output;
    }

    public void Train(List<DataPoint> data, int epochs = 2000)
    {
        // Validation split (80/20)
        int split = (int)(data.Count * 0.8);
        var trainData = data.Take(split).ToList();
        var valData = data.Skip(split).ToList();

        // Normalize training data
        double[] mean, std;
        Normalize(trainData, out mean, out std);

        double bestValLoss = double.MaxValue;
        int patienceCounter = 0;
        int minEpochs = 200;
        _learningRate = _baseLearningRate;

        // Early stopping vars
        double bestValR2 = double.MinValue;

        for (int epoch = 0; epoch < epochs; epoch++)
        {
            // LR warmup + cosine decay
            if (epoch < 100)
                _learningRate = _baseLearningRate * (epoch + 1) / 100.0;
            else
                _learningRate = _baseLearningRate * 0.5 * (1 + Math.Cos(Math.PI * (epoch - 100) / (epochs - 100)));

            Shuffle(trainData);

            double trainLoss = 0;
            bool hasNaN = false;

            // Accumulators for batch norm
            double[] bnSum = new double[_hiddenSize];
            double[] bnSumSq = new double[_hiddenSize];
            int bnCount = 0;

            foreach (var point in trainData)
            {
                // Normalize input
                double[] normalizedInput = NormalizePoint(point.Input, mean, std);

                // Forward pass with batch norm
                double[] hidden = _hiddenPool;
                for (int j = 0; j < _hiddenSize; j++)
                {
                    double sum = _b1[j];
                    for (int i = 0; i < _inputSize; i++)
                        sum += _w1[i, j] * normalizedInput[i];
                    // Batch norm (training: batch stats)
                    bnSum[j] += sum;
                    bnSumSq[j] += sum * sum;
                    double batchMean = bnSum[j] / (bnCount + 1);
                    double batchVar = bnSumSq[j] / (bnCount + 1) - batchMean * batchMean;
                    double normalized = (sum - batchMean) / Math.Sqrt(batchVar + 1e-8);
                    hidden[j] = _bnGamma[j] * normalized + _bnBeta[j];
                    // Dropout (training only)
                    if (_rand.NextDouble() < DropoutRate)
                        hidden[j] = 0;
                    // ReLU
                    hidden[j] = Math.Max(0, hidden[j]);
                }
                bnCount++;

                double predicted = _b2;
                for (int j = 0; j < _hiddenSize; j++)
                    predicted += _w2[j] * hidden[j];

                double actual = point.TargetIPC;
                double error = predicted - actual;

                if (double.IsNaN(error) || double.IsInfinity(error))
                {
                    hasNaN = true;
                    break;
                }

                // Backward pass
                for (int j = 0; j < _hiddenSize; j++)
                {
                    double g = _learningRate * (error * hidden[j] + _l2Lambda * _w2[j]);
                    if (Math.Abs(g) > GradientClipNorm) g = Math.Sign(g) * GradientClipNorm;
                    _w2[j] -= g;
                }
                double gB2 = _learningRate * error;
                if (Math.Abs(gB2) > GradientClipNorm) gB2 = Math.Sign(gB2) * GradientClipNorm;
                _b2 -= gB2;

                for (int i = 0; i < _inputSize; i++)
                    for (int j = 0; j < _hiddenSize; j++)
                    {
                        double g = _learningRate * (error * _w2[j] * (hidden[j] > 0 ? 1 : 0) * normalizedInput[i] + _l2Lambda * _w1[i, j]);
                        if (Math.Abs(g) > GradientClipNorm) g = Math.Sign(g) * GradientClipNorm;
                        _w1[i, j] -= g;
                    }

                for (int j = 0; j < _hiddenSize; j++)
                {
                    double g = _learningRate * (error * _w2[j] * (hidden[j] > 0 ? 1 : 0) + _l2Lambda * _b1[j]);
                    if (Math.Abs(g) > GradientClipNorm) g = Math.Sign(g) * GradientClipNorm;
                    _b1[j] -= g;
                }

                trainLoss += error * error;
            }

            if (hasNaN)
            {
                ReinitWeights();
                bestValLoss = double.MaxValue;
                patienceCounter = 0;
                continue;
            }

            trainLoss /= trainData.Count;

            // Update running batch norm stats (exponential moving average)
            for (int j = 0; j < _hiddenSize; j++)
            {
                double batchMean = bnSum[j] / Math.Max(1, bnCount);
                double batchVar = bnSumSq[j] / Math.Max(1, bnCount) - batchMean * batchMean;
                _bnRunningMean[j] = BnMomentum * _bnRunningMean[j] + (1 - BnMomentum) * batchMean;
                _bnRunningVar[j] = BnMomentum * _bnRunningVar[j] + (1 - BnMomentum) * batchVar;
            }

            // Validation loss
            double valLoss = 0;
            foreach (var point in valData)
            {
                double[] normInput = NormalizePoint(point.Input, mean, std);
                double pred = Predict(normInput);
                double err = pred - point.TargetIPC;
                valLoss += err * err;
            }
            valLoss /= Math.Max(1, valData.Count);

            // Early stopping
            if (epoch >= minEpochs)
            {
                if (valLoss < bestValLoss - MinDelta)
                {
                    bestValLoss = valLoss;
                    patienceCounter = 0;
                }
                else
                {
                    patienceCounter++;
                    if (patienceCounter >= Patience)
                        break;
                }
            }

            if (epoch % 100 == 0 && epoch > 0)
            {
                double trainR2 = ComputeR2(trainData, mean, std);
                double valR2 = ComputeR2(valData, mean, std);
                TrainR2 = trainR2;
                ValR2 = valR2;
            }
        }

        // Final metrics
        TrainR2 = ComputeR2(trainData, mean, std);
        ValR2 = ComputeR2(valData, mean, std);
        TrainRmse = Math.Sqrt(trainData.Average(p => Math.Pow(Predict(NormalizePoint(p.Input, mean, std)) - p.TargetIPC, 2)));
        ValRmse = Math.Sqrt(valData.Average(p => Math.Pow(Predict(NormalizePoint(p.Input, mean, std)) - p.TargetIPC, 2)));
    }

    public void TrainSingle(DataPoint point, int epochs = 20)
    {
        for (int epoch = 0; epoch < epochs; epoch++)
        {
            double predicted = Predict(point.Input);
            double error = predicted - point.TargetIPC;

            double[] hidden = GetHidden(point.Input);

            for (int j = 0; j < _hiddenSize; j++)
                _w2[j] -= _learningRate * error * hidden[j];
            _b2 -= _learningRate * error;

            for (int i = 0; i < _inputSize; i++)
                for (int j = 0; j < _hiddenSize; j++)
                {
                    double grad = error * _w2[j] * (hidden[j] > 0 ? 1 : 0) * point.Input[i];
                    _w1[i, j] -= _learningRate * grad;
                }

            for (int j = 0; j < _hiddenSize; j++)
                _b1[j] -= _learningRate * error * _w2[j] * (hidden[j] > 0 ? 1 : 0);
        }
    }

    private double[] GetHidden(double[] input)
    {
        double[] hidden = _hiddenPool;
        for (int j = 0; j < _hiddenSize; j++)
        {
            double sum = _b1[j];
            for (int i = 0; i < _inputSize; i++)
                sum += _w1[i, j] * input[i];
            // Batch norm (inference — use running stats)
            sum = (sum - _bnRunningMean[j]) / Math.Sqrt(_bnRunningVar[j] + 1e-8);
            sum = _bnGamma[j] * sum + _bnBeta[j];
            hidden[j] = Math.Max(0, sum);
        }
        return hidden;
    }

    private void Normalize(List<DataPoint> data, out double[] mean, out double[] std)
    {
        mean = new double[_inputSize];
        std = new double[_inputSize];
        int n = data.Count;
        if (n == 0) { for (int i = 0; i < _inputSize; i++) std[i] = 1; return; }

        double[] localMean = mean;
        double[] localStd = std;
        for (int i = 0; i < _inputSize; i++)
            localMean[i] = data.Average(p => p.Input[i]);
        for (int i = 0; i < _inputSize; i++)
        {
            int idx = i;
            double variance = data.Average(p => Math.Pow(p.Input[idx] - localMean[idx], 2));
            localStd[i] = Math.Sqrt(variance) + 1e-8;
        }
        mean = localMean;
        std = localStd;
    }

    private double[] NormalizePoint(double[] input, double[] mean, double[] std)
    {
        double[] result = new double[_inputSize];
        for (int i = 0; i < _inputSize; i++)
            result[i] = (input[i] - mean[i]) / std[i];
        return result;
    }

    private double ComputeR2(List<DataPoint> data, double[] mean, double[] std)
    {
        if (data.Count < 2) return 0;
        double meanTarget = data.Average(p => p.TargetIPC);
        double[] localM = mean, localS = std;
        double ssRes = data.Sum(p => Math.Pow(Predict(NormalizePoint(p.Input, localM, localS)) - p.TargetIPC, 2));
        double ssTot = data.Sum(p => Math.Pow(p.TargetIPC - meanTarget, 2));
        return ssTot > 0 ? 1 - ssRes / ssTot : 0;
    }

    private void ReinitWeights()
    {
        double w1Scale = Math.Sqrt(2.0 / (_inputSize + _hiddenSize));
        double w2Scale = Math.Sqrt(2.0 / (_hiddenSize + 1));
        for (int i = 0; i < _inputSize; i++)
            for (int j = 0; j < _hiddenSize; j++)
                _w1[i, j] = (RandGaussian()) * w1Scale;
        for (int j = 0; j < _hiddenSize; j++)
            _w2[j] = (RandGaussian()) * w2Scale;
        _b2 = 0;
        for (int j = 0; j < _hiddenSize; j++)
        {
            _b1[j] = 0;
            _bnGamma[j] = 1.0;
            _bnBeta[j] = 0.0;
        }
    }

    private static void Shuffle<T>(List<T> list)
    {
        var rng = new Random();
        for (int i = list.Count - 1; i > 0; i--)
        {
            int j = rng.Next(i + 1);
            (list[i], list[j]) = (list[j], list[i]);
        }
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var stream = File.Create(path);
        using var writer = new BinaryWriter(stream);

        writer.Write(_inputSize);
        writer.Write(_hiddenSize);

        for (int i = 0; i < _inputSize; i++)
            for (int j = 0; j < _hiddenSize; j++)
                writer.Write(_w1[i, j]);

        for (int j = 0; j < _hiddenSize; j++)
            writer.Write(_b1[j]);

        for (int j = 0; j < _hiddenSize; j++)
            writer.Write(_w2[j]);

        writer.Write(_b2);

        // Save batch norm params
        for (int j = 0; j < _hiddenSize; j++)
            writer.Write(_bnGamma[j]);
        for (int j = 0; j < _hiddenSize; j++)
            writer.Write(_bnBeta[j]);
        for (int j = 0; j < _hiddenSize; j++)
            writer.Write(_bnRunningMean[j]);
        for (int j = 0; j < _hiddenSize; j++)
            writer.Write(_bnRunningVar[j]);

        writer.Write(TrainR2);
        writer.Write(ValR2);
    }

    public static NeuralPredictor Load(string path)
    {
        using var stream = File.OpenRead(path);
        using var reader = new BinaryReader(stream);

        int inputSize = reader.ReadInt32();
        int hiddenSize = reader.ReadInt32();

        var model = new NeuralPredictor(inputSize, hiddenSize);

        for (int i = 0; i < inputSize; i++)
            for (int j = 0; j < hiddenSize; j++)
                model._w1[i, j] = reader.ReadDouble();

        for (int j = 0; j < hiddenSize; j++)
            model._b1[j] = reader.ReadDouble();

        for (int j = 0; j < hiddenSize; j++)
            model._w2[j] = reader.ReadDouble();

        model._b2 = reader.ReadDouble();

        // Load batch norm params (backwards compat)
        try
        {
            for (int j = 0; j < hiddenSize; j++)
                model._bnGamma[j] = reader.ReadDouble();
            for (int j = 0; j < hiddenSize; j++)
                model._bnBeta[j] = reader.ReadDouble();
            for (int j = 0; j < hiddenSize; j++)
                model._bnRunningMean[j] = reader.ReadDouble();
            for (int j = 0; j < hiddenSize; j++)
                model._bnRunningVar[j] = reader.ReadDouble();
            model.TrainR2 = reader.ReadDouble();
            model.ValR2 = reader.ReadDouble();
        }
        catch (EndOfStreamException) { /* old format — use defaults */ }

        return model;
    }

    /// <summary>
    /// Returns a report string with model architecture and metrics.
    /// </summary>
    public string GenerateReport()
    {
        return $"NeuralPredictor: {_inputSize}→{_hiddenSize}→1\n" +
               $"  Activation: ReLU(hidden) + Linear(output)\n" +
               $"  Initialization: Xavier (Glorot)\n" +
               $"  Regularization: L2(lambda={_l2Lambda}), Dropout(rate={DropoutRate})\n" +
               $"  Batch norm: {_hiddenSize} neurons\n" +
               $"  Gradient clip: ±{GradientClipNorm}\n" +
               $"  Learning rate: {_baseLearningRate} (cosine decay)\n" +
               $"  Train R²: {TrainR2:F4}\n" +
               $"  Val R²:   {ValR2:F4}\n" +
               $"  Train RMSE: {TrainRmse:F4}\n" +
               $"  Val RMSE:   {ValRmse:F4}";
    }
}
