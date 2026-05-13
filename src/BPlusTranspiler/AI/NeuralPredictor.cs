namespace BPlusTranspiler.AI;

public class NeuralPredictor
{
    private int _inputSize;
    private int _hiddenSize;

    private double[,] _w1;
    private double[] _b1;
    private double[] _w2;
    private double _b2;

    private double _learningRate = 0.001;

    public NeuralPredictor(int inputSize, int hiddenSize = 16)
    {
        _inputSize = inputSize;
        _hiddenSize = hiddenSize;

        var rand = new Random(42);

        _w1 = new double[_inputSize, _hiddenSize];
        _b1 = new double[_hiddenSize];
        _w2 = new double[_hiddenSize];

        for (int i = 0; i < _inputSize; i++)
            for (int j = 0; j < _hiddenSize; j++)
                _w1[i, j] = (rand.NextDouble() - 0.5) * 0.1;

        for (int j = 0; j < _hiddenSize; j++)
            _b1[j] = 0;

        for (int j = 0; j < _hiddenSize; j++)
            _w2[j] = (rand.NextDouble() - 0.5) * 0.1;

        _b2 = 0;
    }

    public double Predict(double[] input)
    {
        double[] hidden = new double[_hiddenSize];
        for (int j = 0; j < _hiddenSize; j++)
        {
            double sum = _b1[j];
            for (int i = 0; i < _inputSize; i++)
                sum += _w1[i, j] * input[i];
            hidden[j] = Math.Max(0, sum);
        }

        double output = _b2;
        for (int j = 0; j < _hiddenSize; j++)
            output += _w2[j] * hidden[j];

        return output;
    }

    public void Train(List<DataPoint> data, int epochs = 2000)
    {
        double bestLoss = double.MaxValue;
        double l2Lambda = 0.001;
        int minEpochs = 200;

        for (int epoch = 0; epoch < epochs; epoch++)
        {
            Shuffle(data);

            double totalLoss = 0;
            bool hasNaN = false;

            foreach (var point in data)
            {
                double predicted = Predict(point.Input);
                double actual = point.TargetIPC;
                double error = predicted - actual;

                if (double.IsNaN(error) || double.IsInfinity(error))
                {
                    hasNaN = true;
                    break;
                }

                double[] hidden = GetHidden(point.Input);

                for (int j = 0; j < _hiddenSize; j++)
                {
                    double g = _learningRate * (error * hidden[j] + l2Lambda * _w2[j]);
                    if (Math.Abs(g) > 0.5) g = Math.Sign(g) * 0.5;
                    _w2[j] -= g;
                }
                double gB2 = _learningRate * error;
                if (Math.Abs(gB2) > 0.5) gB2 = Math.Sign(gB2) * 0.5;
                _b2 -= gB2;

                for (int i = 0; i < _inputSize; i++)
                    for (int j = 0; j < _hiddenSize; j++)
                    {
                        double g = _learningRate * (error * _w2[j] * (hidden[j] > 0 ? 1 : 0) * point.Input[i] + l2Lambda * _w1[i, j]);
                        if (Math.Abs(g) > 0.5) g = Math.Sign(g) * 0.5;
                        _w1[i, j] -= g;
                    }

                for (int j = 0; j < _hiddenSize; j++)
                {
                    double g = _learningRate * (error * _w2[j] * (hidden[j] > 0 ? 1 : 0) + l2Lambda * _b1[j]);
                    if (Math.Abs(g) > 0.5) g = Math.Sign(g) * 0.5;
                    _b1[j] -= g;
                }

                totalLoss += error * error;
            }

            if (hasNaN)
            {
                var rand = new Random(epoch + 42);
                for (int i = 0; i < _inputSize; i++)
                    for (int j = 0; j < _hiddenSize; j++)
                        _w1[i, j] = (rand.NextDouble() - 0.5) * 0.01;
                for (int j = 0; j < _hiddenSize; j++)
                    _w2[j] = (rand.NextDouble() - 0.5) * 0.01;
                bestLoss = double.MaxValue;
                continue;
            }

            totalLoss /= data.Count;

            if (totalLoss < bestLoss)
                bestLoss = totalLoss;

            if (epoch >= minEpochs && bestLoss < 0.001)
                break;
        }
    }

    public void TrainSingle(DataPoint point, int epochs = 10)
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
        double[] hidden = new double[_hiddenSize];
        for (int j = 0; j < _hiddenSize; j++)
        {
            double sum = _b1[j];
            for (int i = 0; i < _inputSize; i++)
                sum += _w1[i, j] * input[i];
            hidden[j] = Math.Max(0, sum);
        }
        return hidden;
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

        return model;
    }
}
