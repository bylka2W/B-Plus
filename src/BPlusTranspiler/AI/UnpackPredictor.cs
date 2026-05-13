using System;
using System.Collections.Generic;
using System.Linq;
using System.IO;

namespace BPlusTranspiler.AI
{
    public class UnpackPredictor
    {
        private double[,] w1, w2;
        private double[] b1, b2;
        private double lr = 0.01;
        private double lambda = 0.001;
        private double clip = 1.0;

        public UnpackPredictor()
        {
            Random r = new Random(42);
            w1 = new double[12, 8];
            w2 = new double[8, 4];
            b1 = new double[8];
            b2 = new double[4];
            for (int i = 0; i < 12; i++)
                for (int j = 0; j < 8; j++)
                    w1[i, j] = (r.NextDouble() - 0.5) * 0.1;
            for (int i = 0; i < 8; i++)
                for (int j = 0; j < 4; j++)
                    w2[i, j] = (r.NextDouble() - 0.5) * 0.1;
            for (int i = 0; i < 8; i++) b1[i] = 0;
            for (int i = 0; i < 4; i++) b2[i] = 0;
        }

        public double[] Forward(double[] x)
        {
            double[] h = new double[8];
            for (int j = 0; j < 8; j++)
            {
                h[j] = b1[j];
                for (int i = 0; i < 12; i++)
                    h[j] += x[i] * w1[i, j];
                h[j] = Math.Max(0, h[j]);
            }
            double[] y = new double[4];
            for (int k = 0; k < 4; k++)
            {
                y[k] = b2[k];
                for (int j = 0; j < 8; j++)
                    y[k] += h[j] * w2[j, k];
            }
            return y;
        }

        public void Train(List<(double[] x, double[] y)> data, int epochs)
        {
            for (int epoch = 0; epoch < epochs; epoch++)
            {
                double loss = 0;
                foreach (var (x, y) in data)
                {
                    double[] h = new double[8];
                    for (int j = 0; j < 8; j++)
                    {
                        h[j] = b1[j];
                        for (int i = 0; i < 12; i++)
                            h[j] += x[i] * w1[i, j];
                        h[j] = Math.Max(0, h[j]);
                    }
                    double[] pred = new double[4];
                    for (int k = 0; k < 4; k++)
                    {
                        pred[k] = b2[k];
                        for (int j = 0; j < 8; j++)
                            pred[k] += h[j] * w2[j, k];
                    }
                    double errSum = 0;
                    for (int k = 0; k < 4; k++)
                    {
                        double e = y[k] - pred[k];
                        errSum += e * e;
                        double grad = -2 * e;
                        b2[k] -= lr * grad;
                        for (int j = 0; j < 8; j++)
                        {
                            w2[j, k] -= lr * (grad * h[j] + lambda * w2[j, k]);
                            if (h[j] > 0)
                            {
                                double gh = 0;
                                for (int l = 0; l < 4; l++)
                                    gh += (y[l] - pred[l]) * (-w2[j, l]);
                                for (int i = 0; i < 12; i++)
                                    w1[i, j] -= lr * (gh * x[i] + lambda * w1[i, j]);
                                b1[j] -= lr * (gh + lambda * b1[j]);
                            }
                        }
                    }
                    loss += errSum / 4;
                }
                if (epoch % 200 == 0)
                    Console.WriteLine($"UnpackPredictor epoch {epoch}: loss={loss / data.Count:F6}");
            }
        }

        public void Save(string path)
        {
            using var sw = new StreamWriter(path);
            for (int i = 0; i < 12; i++)
                for (int j = 0; j < 8; j++)
                    sw.WriteLine(w1[i, j]);
            for (int i = 0; i < 8; i++)
                for (int j = 0; j < 4; j++)
                    sw.WriteLine(w2[i, j]);
            for (int i = 0; i < 8; i++) sw.WriteLine(b1[i]);
            for (int i = 0; i < 4; i++) sw.WriteLine(b2[i]);
        }

        public static UnpackPredictor Load(string path)
        {
            var up = new UnpackPredictor();
            var lines = File.ReadAllLines(path);
            int idx = 0;
            for (int i = 0; i < 12; i++)
                for (int j = 0; j < 8; j++)
                    up.w1[i, j] = double.Parse(lines[idx++]);
            for (int i = 0; i < 8; i++)
                for (int j = 0; j < 4; j++)
                    up.w2[i, j] = double.Parse(lines[idx++]);
            for (int i = 0; i < 8; i++) up.b1[i] = double.Parse(lines[idx++]);
            for (int i = 0; i < 4; i++) up.b2[i] = double.Parse(lines[idx++]);
            return up;
        }
    }

    public static class UnpackPredictorTrainer
    {
        public static void GenerateTrainingData()
        {
            var data = new List<(double[], double[])>();
            var r = new Random(123);
            for (int i = 0; i < 1000; i++)
            {
                double accessOrder = r.NextDouble();
                double registerPressure = r.NextDouble();
                double extractionCost = r.NextDouble();
                double cacheLinePos = r.NextDouble();
                double bitWidth0 = r.NextDouble();
                double bitWidth1 = r.NextDouble();
                double bitWidth2 = r.NextDouble();
                double temporalLocality = r.NextDouble();
                double extractionCount = r.NextDouble();
                double regSize = r.NextDouble();
                double parallelExtract = r.NextDouble();
                double alignment = r.NextDouble();
                double[] x = new double[] { accessOrder, registerPressure, extractionCost, cacheLinePos,
                    bitWidth0, bitWidth1, bitWidth2, temporalLocality, extractionCount, regSize, parallelExtract, alignment };
                double movzxScore = 1 - accessOrder;
                double shrScore = 1 - temporalLocality;
                double vpermqScore = parallelExtract;
                double vextractScore = 1 - extractionCost;
                double[] y = new double[] { Math.Min(1, movzxScore), Math.Min(1, shrScore),
                    Math.Min(1, vpermqScore), Math.Min(1, vextractScore) };
                data.Add((x, y));
            }
            var up = new UnpackPredictor();
            up.Train(data, 1000);
            up.Save("ai_models/unpack.nn");
            Console.WriteLine("UnpackPredictor trained → ai_models/unpack.nn");
        }
    }
}